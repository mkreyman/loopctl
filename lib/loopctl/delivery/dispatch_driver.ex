defmodule Loopctl.Delivery.DispatchDriver do
  @moduledoc """
  Places queued stories on runners without a human (issue #803).

  `Loopctl.Delivery.Placement.place/4` shipped with #833 and had no caller;
  `POST /api/v1/runners/:runner_id/dispatches` (#842) made it reachable by an operator. This
  is the half that runs on a cadence — the piece the loop's first end-to-end run did without,
  going out by production RPC.

  ## IT IS OFF UNLESS AN OPERATOR TURNS IT ON, and it refuses to start half-configured

  `:dispatch_driver_enabled` defaults to FALSE. It is the one component of this loop that
  spends money and runs code on someone's machines with nobody watching, so the default is
  that it does not.

  `:dispatch_wall_clock_seconds` and `:dispatch_max_turns` have NO DEFAULT. They are the
  loop's cost governor, and the only measured run — 2026-09-14, one story — cost 108 turns,
  28.8 minutes and about USD 10.40. A default here would be my guess quietly becoming the
  operator's policy, which is the shape this epic's own corrections keep naming; unset, the
  driver refuses to run and says which key is missing.

  ## Selection

  Oldest first, and FAIR ACROSS TENANTS: the read ranks each tenant's queue separately and
  takes every tenant's oldest story before any tenant's second. One bound is shared by the
  whole fleet, so a plain global ordering let one tenant with a full queue consume every slot
  of every pass, and no other tenant's work was ever looked at. Oldest-first WITHIN a tenant
  is the part that cannot starve a story, and it is what
  `Loopctl.Workers.TriageTriggerWorker.candidates/0` already uses.

  A candidate must also be `contracted`. The stage row alone is not enough: every release
  path — the lease's `:runner_lost`, `place/4`'s own undo — puts the row back to `queued`
  while setting `agent_status: :pending`, and `Placement.place/4` refuses anything that is not
  `contracted`. Selecting on the stage alone meant a released story was selected for ever,
  with its `updated_at` frozen at the moment of release and therefore permanently near the
  head of an oldest-first queue: twenty of them and the driver never reached a placeable story
  again, while every pass still reported a clean run.

  ## Eligibility is decided BEFORE the claim, on all four facts

  A placement CLAIMS the story first and `Runners.dispatch/3` answers `:ok` the moment it
  broadcasts, so anything discovered after that point is not a refusal the driver can undo —
  it is a story stranded at `claimed` until its lease expires, and then `queued` +
  `:pending`, which nothing re-contracts. So a runner is eligible only when it is

    * CONNECTED (Phoenix Presence, keyed by machine name),
    * not DRAINING, accepts the story's REPO, and does the dispatch KIND — the three facts on
      its join meta, read through `Runners.accepts?/5`, which is the same rule `dispatch/3`
      applies rather than a second copy of it,
    * has a free slot on its row (`in_flight < max_sessions`), and
    * its TENANT has admission headroom (`Loopctl.Runners.Capacity.admit/2`) — an independent
      limit, and the state `RUNNER_MAX_IN_FLIGHT_SESSIONS` exists to produce is precisely one
      where runners sit idle with free slots.

  Each of those refusals, discovered after the claim instead, costs a `dispatches` row, an
  `api_keys` row and an IMMUTABLE chain entry under the tenant's chain advisory lock, once per
  candidate per minute, for ever.

  ## What it does NOT do

  Retry, back off, or remember. A story it could not place stays at `queued` and is a
  candidate again next pass, which is the same shape the triage trigger uses for the same
  reason: the condition that blocked it (no free runner, nothing connected) is one that clears
  on its own, and a driver that tracked attempts would be inventing a policy nobody asked for.

  What is NOT in that class is reported apart from it. A tenant with no operator key, a
  halted tenant, an agent-rooted tenant and a project with no intake source are all states
  that clear only when a person does something, so they are `:blocked` rather than
  `:unplaceable` and they log at ERROR — a queue that never drains while every pass reports
  `:ok` at `info` is indistinguishable from an empty one.
  """

  import Ecto.Query

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @type outcome :: :placed | :no_runner | :unplaceable | :blocked | :errored

  @typedoc "A selected stage row: the three fields a pass reads, not the whole struct."
  @type candidate :: %{
          tenant_id: Ecto.UUID.t(),
          story_id: Ecto.UUID.t(),
          updated_at: NaiveDateTime.t()
        }

  @kind "implement"

  @doc """
  The stories this pass will attempt, at most `limit`, fairly across tenants.

  `queued` AND `contracted` AND under a project bound to exactly ONE active intake source —
  see the moduledoc on why the stage row alone selected released stories for ever, and why an
  unaddressable project is the same trap wearing the driver's own `:blocked` label. Ranked per
  tenant and ordered by that rank first, so a tenant with one queued story is reached in the
  same pass as a tenant with two hundred.

  Fleet-wide and with no tenant in the predicate, exactly like the triage trigger's own
  candidate read — and carrying the same cost, which migration `20260921110000` documents for
  that one: a read on this shape with no supporting index sorts the whole table every pass.
  `story_stages_queued_idx` is its counterpart, keyed `(tenant_id, updated_at, story_id)` to
  match the window's PARTITION BY plus its ORDER BY.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [candidate()]
  def candidates(limit) when is_integer(limit) and limit > 0 do
    # ONE ACTIVE INTAKE SOURCE, in the predicate rather than discovered per story. A project
    # with none has no repository and a project with two names no single one, so every story
    # under it is `:blocked` — and a blocked story's `updated_at` never moves, which put it at
    # the head of an oldest-first queue for ever. Twenty of them filled every pass's batch
    # while the job reported a clean run: the same trap the `contracted` predicate closed for
    # released stories, left open for the class this driver's own reporting introduced.
    bound_projects =
      from src in Source,
        where: is_nil(src.revoked_at),
        group_by: [src.tenant_id, src.project_id],
        having: count(src.id) == 1,
        select: %{tenant_id: src.tenant_id, project_id: src.project_id}

    ranked =
      from s in StoryStage,
        join: st in Story,
        on: st.id == s.story_id and st.tenant_id == s.tenant_id,
        join: b in subquery(bound_projects),
        on: b.tenant_id == st.tenant_id and b.project_id == st.project_id,
        where: s.stage == :queued,
        where: st.agent_status == :contracted,
        select: %{
          tenant_id: s.tenant_id,
          story_id: s.story_id,
          updated_at: s.updated_at,
          rank:
            over(row_number(),
              partition_by: s.tenant_id,
              order_by: [asc: s.updated_at, asc: s.story_id]
            )
        }

    Loopctl.AdminRepo.all(
      from r in subquery(ranked),
        order_by: [asc: r.rank, asc: r.updated_at, asc: r.story_id],
        limit: ^limit,
        select: %{tenant_id: r.tenant_id, story_id: r.story_id, updated_at: r.updated_at}
    )
  end

  @doc """
  A runner of `tenant_id` that would accept an `implement` dispatch for `repo` right now, or
  `nil`.

  Every half of the moduledoc's eligibility rule, in the order that costs least: the tenant's
  admission headroom is one aggregate read and gates the whole pass for that tenant; the
  presence metas answer draining, repos and kind with no database at all; the row read is what
  answers capacity. Fewest slots first, so a fleet spreads rather than filling one machine.
  """
  @spec available_runner(Ecto.UUID.t(), String.t()) :: Runner.t() | nil
  def available_runner(tenant_id, repo) when is_binary(tenant_id) and is_binary(repo) do
    with :ok <- Capacity.admit(Loopctl.AdminRepo, tenant_id),
         [_ | _] = ids <- accepting_runner_ids(tenant_id, repo) do
      Loopctl.AdminRepo.one(
        from r in Runner,
          where: r.tenant_id == ^tenant_id,
          where: is_nil(r.revoked_at),
          where: r.id in ^ids,
          where: r.in_flight < r.max_sessions,
          order_by: [asc: r.in_flight],
          limit: 1
      )
    else
      _admission_reached_or_nobody_accepting -> nil
    end
  end

  # The runners whose OWN declaration admits this dispatch, read from the meta of the socket a
  # push would reach. A machine with two live sockets on one credential is skipped rather than
  # guessed at: `Runners.dispatch/3` refuses that as `:runner_ambiguous`, so placing on it
  # would take a claim for a dispatch that cannot be delivered.
  defp accepting_runner_ids(tenant_id, repo) do
    for {_name, %{metas: [meta]}} <- Runners.pool(tenant_id),
        runner_id = Map.get(meta, :runner_id),
        is_binary(runner_id),
        Runners.accepts?(tenant_id, runner_id, meta, @kind, repo) == :ok,
        do: runner_id
  end

  @doc """
  The budgets, or `{:error, {:unset, key}}` when either is missing.

  NO DEFAULT, deliberately — see the moduledoc. Read once per pass and threaded, rather than
  per story, so a pass either has a policy or does not run at all.
  """
  @spec budgets() ::
          {:ok, %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}}
          | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def budgets do
    with {:ok, seconds} <- fetch_budget(:dispatch_wall_clock_seconds),
         {:ok, turns} <- fetch_budget(:dispatch_max_turns) do
      {:ok, %{wall_clock_seconds: seconds, max_turns: turns}}
    end
  end

  defp fetch_budget(key), do: normalise_budget(Application.get_env(:loopctl, key), key)

  @doc """
  A configured budget value, or `{:error, {:unset, key}}` for anything unusable.

  A POSITIVE INTEGER or nothing. `nil` is the unset case; zero, a negative, a string from a
  hand-edited config and a float are all the same answer, because each one means the operator
  did not state a policy this driver can spend against — and a zero budget in particular would
  mint dispatches that die on arrival.

  Public because the config read itself cannot be exercised: this repo forbids
  `Application.put_env` in tests, so the key is unset in every one and the branches below
  would otherwise be reachable only from production.
  """
  @spec normalise_budget(term(), atom()) ::
          {:ok, pos_integer()} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def normalise_budget(value, key) when is_atom(key) do
    cond do
      not (is_integer(value) and value > 0) -> {:error, {:unset, key}}
      value > budget_maximum(key) -> {:error, {:over_contract_maximum, key}}
      true -> {:ok, value}
    end
  end

  # THE CONTRACT'S OWN CEILING, read from the contract rather than copied. A wall clock over
  # `RunnerDispatch.max_wall_clock_seconds/0` is refused by `cast_dispatch/1` INSIDE
  # `Runners.dispatch/3` — which is after the claim, so an operator who set a two-day budget
  # would spend twenty mint-claim-refuse-release cycles a minute, each one a permanent chain
  # entry, for a number the contract was never going to accept. Read once per pass here, and
  # the pass does not run at all.
  #
  # `max_turns` has a minimum in the contract and no maximum, so its only ceiling is the one
  # above: a positive integer. Stated rather than left implicit, because the pair is read as a
  # pair and a silent `:infinity` for one of them is how the other's bound gets forgotten.
  # ONE CEILING PER BUDGET KEY, and every key a caller may pass must have a clause — this is a
  # private function on a public entry point, so a key it does not name is a
  # `FunctionClauseError` inside an Oban worker rather than an error return. The triage pair
  # (`Loopctl.Delivery.TriageDispatcher.budgets/0`, `DispatchPayload.fill/3` on a triage kind)
  # had no clause, so setting `TRIAGE_WALL_CLOCK_SECONDS` — which is what the deploy doc tells
  # an operator to do — crashed every pass, three Oban retries and a discard a minute, with no
  # triage dispatch ever sent. It was green because the only budget test asserts the UNSET
  # path, which returns before reaching here.
  #
  # Triage runs against the same wire field as implement, so it is bounded by the same
  # contract maximum. It is not a policy choice: `cast_dispatch/1` refuses anything above it.
  defp budget_maximum(key) when key in [:dispatch_wall_clock_seconds, :triage_wall_clock_seconds],
    do: RunnerContract.RunnerDispatch.max_wall_clock_seconds()

  defp budget_maximum(key) when key in [:dispatch_max_turns, :triage_max_turns], do: :infinity

  @doc "True when an operator has turned the driver on. Defaults to FALSE."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:loopctl, :dispatch_driver_enabled, false) == true

  @doc """
  One pass: place what can be placed, and report what each candidate did.

  Returns `{:error, {:unset, key}}` rather than running when a budget is missing, and
  `{:ok, []}` when the driver is off — off is not a failure.
  """
  @spec run(pos_integer()) ::
          {:ok, [outcome()]} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def run(limit) when is_integer(limit) and limit > 0 do
    if enabled?() do
      with {:ok, budgets} <- budgets(), do: {:ok, run_with(limit, budgets)}
    else
      {:ok, []}
    end
  end

  @doc """
  The pass itself, on budgets already decided: what `run/1` does once both gates pass.

  Separate from `run/1` for the same reason `normalise_budget/2` is — the gates read
  application config, which a test may not set, so this is the only way the placing path is
  reachable from a test at all. `run/1` is the config decision; this is the work.

  The tenant-level facts a pass resolves are cached ACROSS candidates and the runner facts
  are not, and the split is deliberate: a tenant's operator key does not change while a pass
  runs, while its runners' free slots change with every story this very pass places.
  """
  @spec run_with(pos_integer(), %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}) ::
          [outcome()]
  def run_with(limit, budgets) when is_integer(limit) and limit > 0 do
    {outcomes, _cache} =
      limit
      |> candidates()
      |> Enum.map_reduce(%{}, fn candidate, cache -> attempt(candidate, budgets, cache) end)

    outcomes
  end

  # ONE STORY MAY NOT KILL THE PASS, the lesson `TriageTriggerWorker` records: the read is
  # oldest-first, so a story that raises sits at the head of every later batch too, and one
  # row would stall the fleet. EXITS as well as raises — a pool checkout timeout exits.
  defp attempt(candidate, budgets, cache) do
    {result, cache} = place(candidate, budgets, cache)

    outcome =
      case result do
        {:ok, _placed} ->
          :placed

        {:error, :no_runner} ->
          :no_runner

        {:error, reason} when reason in [:no_operator_key, :tenant_halted] ->
          blocked(candidate, reason)

        {:error, {:no_intake_source, _} = reason} ->
          blocked(candidate, reason)

        {:error, {:ambiguous_intake_source, _, _} = reason} ->
          blocked(candidate, reason)

        {:error, :custody_tier_required} ->
          blocked(candidate, :custody_tier_required)

        {:error, reason} ->
          unplaceable(candidate, reason)
      end

    {outcome, cache}
  rescue
    error -> {errored(candidate, Exception.format(:error, error, __STACKTRACE__)), cache}
  catch
    kind, value -> {errored(candidate, Exception.format(kind, value, __STACKTRACE__)), cache}
  end

  defp place(candidate, budgets, cache) do
    %{tenant_id: tenant_id, story_id: story_id} = candidate

    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         %Runner{} = runner <-
           available_runner(tenant_id, source.repo_full_name) || {:error, :no_runner},
         {{:ok, key}, cache} <- operator_key(tenant_id, cache) do
      {Placement.place(tenant_id, runner.id, dispatch(story, source, budgets),
         api_key: key,
         actor_label: "worker:dispatch_driver"
       ), cache}
    else
      {{:error, _reason} = error, %{} = cache} -> {error, cache}
      {:error, reason} -> {{:error, reason}, cache}
      nil -> {{:error, :no_runner}, cache}
    end
  end

  # NO `branch` KEY, WHICH IS HOW THE TWO PATHS ARE MADE UNABLE TO DISAGREE (story 846.2).
  # This used to call `DispatchPayload.branch_for/1` here, which was the same function an
  # operator's placement used and therefore the same name — until the derivation gained an
  # input this module does not have. Since contract 1.14.0 the branch depends on what the
  # TARGET RUNNER declared it accepts (`RunnerJoin.branch_prefixes`), read off the live socket
  # the push will reach, and only `Loopctl.Delivery.Placement` holds that. A second derivation
  # here would have to re-read the pool and could still resolve a different meta, so the key
  # is omitted and `DispatchPayload.fill/3` fills it: one call site, no copy to drift.
  #
  # The budgets are passed rather than re-read: a pass reads them once, so every story it
  # places spends against the same policy even if an operator changes it mid-pass.
  defp dispatch(story, source, budgets) do
    %{
      "dispatch_id" => Ecto.UUID.generate(),
      "story_id" => story.id,
      "kind" => @kind,
      "repo" => source.repo_full_name,
      "base_branch" => source.base_branch,
      "wall_clock_seconds" => budgets.wall_clock_seconds,
      "max_turns" => budgets.max_turns
    }
  end

  defp fetch_story(tenant_id, story_id) do
    {:ok, story} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)
      end)

    if story, do: {:ok, story}, else: {:error, :story_not_found}
  end

  # THE TENANT'S OPERATOR KEY — an unlineaged `:user` key, which is what `place/4`'s ceiling
  # admits for a caller that no dispatch minted. A driver has no request and therefore no
  # authenticated principal of its own, so it acts as the tenant's operator; anything else
  # would mean minting a credential for a worker, which is a root the custody chain does not
  # have. A tenant with no such key cannot be driven, and that is reported rather than
  # worked around.
  #
  # NEITHER REVOKED NOR EXPIRED. `Loopctl.Auth` refuses an expired key on every request, and
  # expiry is what key ROTATION uses — `expire_api_key/2` — so a rotated-out key is expired
  # and not revoked. `Placement.resolve_caller/2` validates neither, so an expired key here
  # would mint dispatches and drive custody transitions that the HTTP pipeline would have
  # 401'd. Oldest first among what is left, which is the tenant's original operator key.
  #
  # CACHED PER PASS, keyed by tenant: it cannot change while a pass runs, and the read is on
  # the three-connection AdminRepo pool that every authenticated request in the fleet shares.
  defp operator_key(tenant_id, cache) do
    case Map.fetch(cache, {:operator_key, tenant_id}) do
      {:ok, cached} ->
        {cached, cache}

      :error ->
        now = DateTime.utc_now()

        key =
          Loopctl.AdminRepo.one(
            from k in Loopctl.Auth.ApiKey,
              where: k.tenant_id == ^tenant_id and k.role == :user,
              where: is_nil(k.revoked_at),
              where: is_nil(k.expires_at) or k.expires_at > ^now,
              order_by: [asc: k.inserted_at],
              limit: 1
          )

        result = if key, do: {:ok, key}, else: {:error, :no_operator_key}
        {result, Map.put(cache, {:operator_key, tenant_id}, result)}
    end
  end

  defp unplaceable(candidate, reason) do
    Logger.info(
      "DispatchDriver: leaving for the next pass: story_id=#{candidate.story_id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :unplaceable
  end

  # A STATE THAT CLEARS ONLY WHEN A PERSON ACTS, which is why it is not `:unplaceable` and why
  # it is ERROR. The job still succeeds — retrying a misconfiguration every minute is noise,
  # not a signal — but an operator watching a queue that never drains has something to read,
  # and it names the tenant and the reason rather than leaving them to infer both from silence.
  defp blocked(candidate, reason) do
    Logger.error(
      "DispatchDriver: BLOCKED until somebody changes something — this will not clear by " <>
        "itself: story_id=#{candidate.story_id} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :blocked
  end

  defp errored(candidate, detail) do
    Logger.error(
      "DispatchDriver: candidate failed, continuing with the rest of the pass: " <>
        "story_id=#{candidate.story_id} detail=#{detail}",
      tenant_id: candidate.tenant_id
    )

    :errored
  end
end
