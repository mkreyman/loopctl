defmodule Loopctl.Agents.VerifierPlacement do
  @moduledoc """
  Places one `verify@1` candidate (US-48.18): a verifier dispatch B rooted apart from the
  implementer's, bound to the story, and a `verify` runner dispatch whose id IS B's.

  ## What it does, in order

  1. **The story and its stage row**, re-read: the row must be at `ci` with a `head_sha`, a
     `pr_number` and a usable `branch`, and its head must still be unverified. A candidate that
     moved since the candidate read is `{:error, :not_verifiable}` (left for the next pass).
  2. **The source**, in mode `pr`, with a usable base branch.
  3. **The tenant**: not custody-halted, human-anchored — the gates `Placement.place/4` applies
     before it mints, applied here for the same reason (this path mints too).
  4. **The runners**: every selectable runner for `verify`, minus any whose agent is the
     implementer's — the story's `assigned_agent_id` and the implementer dispatch row's
     `agent_id` — and any with no agent. A verifier on the implementer's agent would be refused
     by `Progress.bind_verifier_dispatch/4` anyway; excluding it first means another machine
     is tried instead.
  5. **No independent runner**: when the selectable runners are ALL the implementer's agent's
     and the tenant has no live runner with any other agent at all, no pass will ever find one,
     so the story escalates at `ci` over `:no_independent_verifier_runner` for a person to add a
     machine. Otherwise — no runner selectable now, or another agent's machine is merely busy
     or disconnected — it is `:no_runner`, and the next pass looks again.
  6. **Mint B** under the operator key as a NEW ROOT (`parent_dispatch_id: nil`), role
     `:orchestrator`, for the runner's agent and this story, expiring at the session's wall
     clock plus the lease grace. Its raw key is discarded: B's key never leaves loopctl, and
     the runner is sent no credential. A mint refused for one runner (its agent already holds a
     live `:orchestrator` key, `api_keys_one_role_per_agent_idx`) tries the next. Before the
     mint, the story's PREVIOUS verifier dispatch, if it is expired and unrevoked, is revoked:
     the index above ignores expiry, so a lapsed B would otherwise block its agent for ever.
  7. **Bind B** — `Progress.bind_verifier_dispatch/4`, which fails CLOSED on an empty lineage,
     a shared root or the implementer's agent, and retires any earlier report or verification.
  8. **Push** the `verify` dispatch: `dispatch_id` = B's id, the story object, and
     `verify: {pr_number, head_sha}` off the stage row.

  A refusal after the mint revokes B. B stays bound to the story when the push fails, revoked,
  which `:no_live_verifier_dispatch` reads as "nothing in flight", so the next pass places
  again and the bind overwrites it.

  ## Custody identity

  Everything here is read from loopctl's own rows: the operator key from `api_keys`, the agent
  from `runners`, the lineage from the dispatch row the mint returns. Nothing comes from a
  runner message.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.DispatchLease
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryPayload
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.GitRef
  alias Loopctl.Intake
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Story

  @escalation_reason "verify_dispatch:no_independent_verifier_runner"

  @min_expiry 60
  @max_expiry 14_400

  @type outcome :: :dispatched | :escalated
  @type budgets :: %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}

  @doc """
  Places `story_id` for verification. See the moduledoc.

  Options (all required): `:api_key` — the tenant's operator key, resolved by the caller from
  the database; `:runners` — `fn repo -> [Runner.t()]`, the selectable runners for `verify`;
  `:dispatch` — the push, `&Loopctl.Runners.dispatch/3`; `:actor_label`.

  Returns `{:ok, :dispatched}`, `{:ok, :escalated}`, `{:error, :no_runner}` or another refusal.
  """
  @spec place(Ecto.UUID.t(), Ecto.UUID.t(), budgets(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def place(tenant_id, story_id, budgets, opts) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, stage} <- verifiable_stage(tenant_id, story_id),
         {:ok, source} <- pr_source(tenant_id, story),
         :ok <- not_halted(tenant_id),
         :ok <- Tenants.require_human_anchor(tenant_id),
         {:ok, caller} <- operator(tenant_id, Keyword.fetch!(opts, :api_key)),
         {:ok, excluded} <- implementer_agents(tenant_id, story) do
      runners = Keyword.fetch!(opts, :runners).(source.repo_full_name)

      case independent(runners, excluded) do
        [] ->
          no_independent(tenant_id, story, runners, excluded, opts)

        candidates ->
          :ok = retire_lapsed_verifier(tenant_id, story, caller)
          ctx = %{story: story, stage: stage, source: source, budgets: budgets, caller: caller}
          place_on_first(tenant_id, candidates, ctx, opts)
      end
    end
  end

  @doc "The reason an escalation over `:no_independent_verifier_runner` carries."
  @spec escalation_reason() :: String.t()
  def escalation_reason, do: @escalation_reason

  # ── reads ───────────────────────────────────────────────────────────────────────────────────

  defp fetch_story(tenant_id, story_id) do
    case AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp verifiable_stage(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      %StoryStage{stage: :ci, head_sha: head, pr_number: pr, branch: branch} = row
      when is_binary(head) and is_integer(pr) and pr > 0 and is_binary(branch) ->
        cond do
          row.verified_head_sha == head -> {:error, :not_verifiable}
          not usable_ref?(branch) -> {:error, :invalid_branch}
          true -> {:ok, row}
        end

      _ ->
        {:error, :not_verifiable}
    end
  end

  defp pr_source(tenant_id, story) do
    case Intake.source_for_project(tenant_id, story.project_id) do
      {:ok, %{mode: :pr} = source} ->
        if usable_ref?(source.base_branch),
          do: {:ok, source},
          else: {:error, :invalid_base_branch}

      {:ok, _chg} ->
        {:error, :not_pr_route}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp usable_ref?(branch), do: GitRef.valid_name?(branch) and byte_size(branch) <= 255

  defp not_halted(tenant_id) do
    if Runners.custody_halted?(tenant_id), do: {:error, :tenant_halted}, else: :ok
  end

  # The operator test `Placement` applies to a root mint: a `:user` key that no dispatch
  # minted. The caller resolved the key from the database; this re-derives its lineage rather
  # than trusting the caller to have filtered.
  defp operator(tenant_id, %ApiKey{tenant_id: tenant_id, id: id, role: :user}) do
    case Dispatches.lineage_for_api_key(tenant_id, id) do
      [] -> {:ok, %{id: id, lineage: []}}
      _ -> {:error, :no_operator_key}
    end
  end

  defp operator(_tenant_id, _key), do: {:error, :no_operator_key}

  # Who the verifier must not be: the story's assigned agent and the implementer dispatch's.
  defp implementer_agents(_tenant_id, %Story{implementer_dispatch_id: nil}),
    do: {:error, :missing_implementer_dispatch}

  defp implementer_agents(tenant_id, %Story{} = story) do
    case Dispatches.get_dispatch(tenant_id, story.implementer_dispatch_id) do
      {:ok, %Dispatch{agent_id: agent_id}} ->
        {:ok, Enum.reject(Enum.uniq([story.assigned_agent_id, agent_id]), &is_nil/1)}

      {:error, _} ->
        {:error, :unresolvable_dispatch_lineage}
    end
  end

  defp independent(runners, excluded),
    do: Enum.filter(runners, &(is_binary(&1.agent_id) and &1.agent_id not in excluded))

  # ── no independent runner ───────────────────────────────────────────────────────────────────

  defp no_independent(tenant_id, story, runners, excluded, opts) do
    if runners != [] and not other_agent_runner?(tenant_id, excluded),
      do: escalate(tenant_id, story, opts),
      else: {:error, :no_runner}
  end

  # A live (unrevoked) runner of the tenant with an agent that is not the implementer's.
  defp other_agent_runner?(tenant_id, excluded) do
    AdminRepo.exists?(
      from r in Runner,
        where: r.tenant_id == ^tenant_id and is_nil(r.revoked_at),
        where: not is_nil(r.agent_id) and r.agent_id not in ^excluded
    )
  end

  defp escalate(tenant_id, story, opts) do
    case Stages.advance(tenant_id, story.id, {:ci, :escalated, :no_independent_verifier_runner},
           claim_epoch: story.claim_epoch,
           reason: @escalation_reason,
           actor_label: Keyword.fetch!(opts, :actor_label),
           actor_role: :agent,
           actor_lineage: [],
           row_guard: fn row ->
             if is_binary(row.head_sha) and row.verified_head_sha != row.head_sha,
               do: :ok,
               else: {:error, :not_verifiable}
           end
         ) do
      {:ok, _row} -> {:ok, :escalated}
      {:error, :stale_stage} -> {:error, :not_verifiable}
      {:error, reason} -> {:error, {:escalate_failed, reason}}
    end
  end

  # ── the mint, the bind and the push ─────────────────────────────────────────────────────────

  # The story's previous B, lapsed: the candidate read admitted the story only because no
  # verifier dispatch of it is live, so an unrevoked one here is EXPIRED, and an expired,
  # unrevoked dispatch still holds its agent's slot in `api_keys_one_role_per_agent_idx`.
  defp retire_lapsed_verifier(_tenant_id, %Story{verifier_dispatch_id: nil}, _caller), do: :ok

  defp retire_lapsed_verifier(tenant_id, %Story{verifier_dispatch_id: id}, caller) do
    case Dispatches.get_dispatch(tenant_id, id) do
      {:ok, %Dispatch{revoked_at: nil, parent_dispatch_id: nil}} ->
        _ = revoke(tenant_id, id, caller)
        :ok

      _ ->
        :ok
    end
  end

  defp place_on_first(tenant_id, runners, ctx, opts) do
    Enum.reduce_while(runners, {:error, :no_runner}, fn runner, _last ->
      case mint(tenant_id, runner, ctx) do
        {:ok, dispatch} -> {:halt, bind_and_push(tenant_id, runner, dispatch, ctx, opts)}
        {:error, reason} -> {:cont, {:error, {:verifier_mint_failed, reason}}}
      end
    end)
  end

  defp mint(tenant_id, runner, ctx) do
    attrs = %{
      parent_dispatch_id: nil,
      role: :orchestrator,
      agent_id: runner.agent_id,
      story_id: ctx.story.id,
      expires_in_seconds: expiry(ctx.budgets.wall_clock_seconds)
    }

    case Dispatches.create_dispatch(tenant_id, attrs, actor_lineage: ctx.caller.lineage) do
      # The raw key is dropped here, deliberately: nothing outside loopctl ever holds B's key.
      {:ok, %{dispatch: dispatch}} -> {:ok, dispatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expiry(wall_clock_seconds) do
    grace = DispatchLease.grace_seconds()
    grace = if is_integer(grace) and grace >= 0, do: grace, else: 0

    (wall_clock_seconds + grace)
    |> max(@min_expiry)
    |> min(@max_expiry)
  end

  defp bind_and_push(tenant_id, runner, dispatch, ctx, opts) do
    actor_label = Keyword.fetch!(opts, :actor_label)

    with {:ok, _story} <-
           Progress.bind_verifier_dispatch(tenant_id, ctx.story.id, dispatch.id,
             actor_label: actor_label
           ),
         {:ok, object} <-
           StoryPayload.build(tenant_id, ctx.story.id,
             claim_epoch: ctx.story.claim_epoch,
             actor_lineage: [],
             actor_label: actor_label
           ),
         :ok <-
           Keyword.fetch!(opts, :dispatch).(
             tenant_id,
             runner.id,
             payload(dispatch, object, ctx)
           ) do
      {:ok, :dispatched}
    else
      {:error, reason} ->
        _ = revoke(tenant_id, dispatch.id, ctx.caller)
        {:error, reason}
    end
  end

  defp payload(dispatch, object, ctx) do
    %{
      "dispatch_id" => dispatch.id,
      "story_id" => ctx.story.id,
      "kind" => "verify",
      "repo" => ctx.source.repo_full_name,
      "branch" => ctx.stage.branch,
      "base_branch" => ctx.source.base_branch,
      "claim_epoch" => ctx.story.claim_epoch,
      "wall_clock_seconds" => ctx.budgets.wall_clock_seconds,
      "max_turns" => ctx.budgets.max_turns,
      "story" => object,
      "verify" => %{"pr_number" => ctx.stage.pr_number, "head_sha" => ctx.stage.head_sha}
    }
  end

  defp revoke(tenant_id, dispatch_id, caller) do
    case Dispatches.revoke(tenant_id, dispatch_id, actor_lineage: caller.lineage) do
      {:ok, _} = ok ->
        ok

      other ->
        Logger.error(
          "verifier dispatch not revoked; its key stays live until it expires and holds its " <>
            "agent's :orchestrator slot. Revoke it (MCP revoke_dispatch): " <>
            "tenant_id=#{tenant_id} dispatch_id=#{dispatch_id} outcome=#{inspect(other)}",
          tenant_id: tenant_id
        )

        other
    end
  rescue
    error ->
      Logger.error(
        "verifier dispatch revoke raised: tenant_id=#{tenant_id} dispatch_id=#{dispatch_id} " <>
          "error=#{Exception.message(error)}",
        tenant_id: tenant_id
      )

      {:error, error}
  end
end
