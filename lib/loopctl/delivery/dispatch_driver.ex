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

  Oldest first, fleet-wide, bounded per pass. Oldest-first is the only order that cannot
  starve a story, and it is what `Loopctl.Workers.TriageTriggerWorker.candidates/0` already
  uses — one selection convention in this loop rather than two.

  A runner is eligible when it is CONNECTED (Phoenix Presence, keyed by machine name) and has
  a free slot (`in_flight < max_sessions` on its row). Both halves are required and neither
  implies the other: a runner can hold slots while disconnected, and a connected one can be
  full. Checked BEFORE placing rather than after, because `place/4` refuses
  `:runner_at_capacity` only once the claim is taken, and an undo per attempt is not a
  selection strategy.

  ## What it does NOT do

  Retry, back off, or remember. A story it could not place stays at `queued` and is a
  candidate again next pass, which is the same shape the triage trigger uses for the same
  reason: the condition that blocked it (no free runner, a repo it cannot resolve) is one
  that clears on its own or needs a human, and a driver that tracked attempts would be
  inventing a policy nobody asked for.
  """

  import Ecto.Query

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @type outcome :: :placed | :no_runner | :unplaceable | :errored

  @doc """
  The stage rows this pass will attempt, oldest first, at most `limit`.

  Fleet-wide and with no tenant in the predicate, exactly like the triage trigger's own
  candidate read — and carrying the same cost, which migration `20260921110000` documents for
  that one: a read on this shape with no supporting index sorts the whole table every pass.
  `story_stages_queued_idx` is its counterpart.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [StoryStage.t()]
  def candidates(limit) when is_integer(limit) and limit > 0 do
    Loopctl.AdminRepo.all(
      from s in StoryStage,
        where: s.stage == :queued,
        order_by: [asc: s.updated_at, asc: s.story_id],
        limit: ^limit
    )
  end

  @doc """
  A runner of `tenant_id` that is connected AND has a free slot, or `nil`.

  Both halves, and neither implies the other. `Runners.pool/1` answers who is CONNECTED,
  keyed by machine name; the `runners` row answers who has CAPACITY. A runner that crashed
  holding slots is in the second set and not the first; a busy runner is in the first and not
  the second. Placing on either is a claim taken and then undone.
  """
  @spec available_runner(Ecto.UUID.t()) :: Runner.t() | nil
  def available_runner(tenant_id) when is_binary(tenant_id) do
    connected = tenant_id |> Runners.pool() |> Map.keys() |> MapSet.new()

    if MapSet.size(connected) == 0 do
      nil
    else
      names = MapSet.to_list(connected)

      Loopctl.AdminRepo.one(
        from r in Runner,
          where: r.tenant_id == ^tenant_id,
          where: is_nil(r.revoked_at),
          where: r.name in ^names,
          where: r.in_flight < r.max_sessions,
          order_by: [asc: r.in_flight],
          limit: 1
      )
    end
  end

  @doc """
  The budgets, or `{:error, {:unset, key}}` when either is missing.

  NO DEFAULT, deliberately — see the moduledoc. Read once per pass and threaded, rather than
  per story, so a pass either has a policy or does not run at all.
  """
  @spec budgets() ::
          {:ok, %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}}
          | {:error, {:unset, atom()}}
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
  @spec normalise_budget(term(), atom()) :: {:ok, pos_integer()} | {:error, {:unset, atom()}}
  def normalise_budget(value, key) when is_atom(key) do
    if is_integer(value) and value > 0, do: {:ok, value}, else: {:error, {:unset, key}}
  end

  @doc "True when an operator has turned the driver on. Defaults to FALSE."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:loopctl, :dispatch_driver_enabled, false) == true

  @doc """
  One pass: place what can be placed, and report what each candidate did.

  Returns `{:error, {:unset, key}}` rather than running when a budget is missing, and
  `{:ok, []}` when the driver is off — off is not a failure.
  """
  @spec run(pos_integer()) :: {:ok, [outcome()]} | {:error, {:unset, atom()}}
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
  """
  @spec run_with(pos_integer(), %{wall_clock_seconds: pos_integer(), max_turns: pos_integer()}) ::
          [outcome()]
  def run_with(limit, budgets) when is_integer(limit) and limit > 0 do
    Enum.map(candidates(limit), &attempt(&1, budgets))
  end

  # ONE STORY MAY NOT KILL THE PASS, the lesson `TriageTriggerWorker` records: the read is
  # oldest-first, so a story that raises sits at the head of every later batch too, and one
  # row would stall the fleet. EXITS as well as raises — a pool checkout timeout exits.
  defp attempt(%StoryStage{} = stage, budgets) do
    case place(stage, budgets) do
      {:ok, _placed} -> :placed
      {:error, :no_runner} -> :no_runner
      {:error, reason} -> unplaceable(stage, reason)
    end
  rescue
    error -> errored(stage, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(stage, Exception.format(kind, value, __STACKTRACE__))
  end

  defp place(%StoryStage{} = stage, budgets) do
    # THE RUNNER FIRST, and the order is a decision rather than a habit: with nothing
    # connected — the ordinary state of an idle fleet — every candidate answers `:no_runner`
    # after one presence read, instead of resolving a repository and an operator key for work
    # nobody is going to take. It also makes the pass's report say the true thing: a queue
    # standing still because no machine is joined reads as `:no_runner` rather than as a
    # property of the first story in it.
    with %Runner{} = runner <- available_runner(stage.tenant_id) || {:error, :no_runner},
         {:ok, story} <- fetch_story(stage),
         {:ok, repo} <- MergePrecondition.repo_for_story(story),
         {:ok, key} <- operator_key(stage.tenant_id) do
      Placement.place(stage.tenant_id, runner.id, dispatch(stage, story, repo, budgets),
        api_key: key,
        actor_label: "worker:dispatch_driver"
      )
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_runner}
    end
  end

  defp dispatch(%StoryStage{} = stage, story, repo, budgets) do
    %{
      "dispatch_id" => Ecto.UUID.generate(),
      "story_id" => stage.story_id,
      "kind" => "implement",
      "repo" => repo,
      "branch" => "feature/story-#{story.number}",
      "base_branch" => "master",
      "wall_clock_seconds" => budgets.wall_clock_seconds,
      "max_turns" => budgets.max_turns
    }
  end

  defp fetch_story(%StoryStage{tenant_id: tenant_id, story_id: story_id}) do
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
  defp operator_key(tenant_id) do
    key =
      Loopctl.AdminRepo.one(
        from k in Loopctl.Auth.ApiKey,
          where: k.tenant_id == ^tenant_id and k.role == :user,
          where: is_nil(k.revoked_at),
          order_by: [asc: k.inserted_at],
          limit: 1
      )

    if key, do: {:ok, key}, else: {:error, :no_operator_key}
  end

  defp unplaceable(%StoryStage{} = stage, reason) do
    Logger.info(
      "DispatchDriver: leaving for the next pass: story_id=#{stage.story_id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: stage.tenant_id
    )

    :unplaceable
  end

  defp errored(%StoryStage{} = stage, detail) do
    Logger.error(
      "DispatchDriver: candidate failed, continuing with the rest of the pass: " <>
        "story_id=#{stage.story_id} detail=#{detail}",
      tenant_id: stage.tenant_id
    )

    :errored
  end
end
