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

  ## The pass runs from `implement@1` (US-48.7)

  Every pass here is `Loopctl.Agents.Dispatcher.run/2` over `Loopctl.Agents.Specs.ImplementV1`,
  the `:build` archetype: the candidates, the admission pre-check and runner selection
  (`spec.runner`), the operator key, the dispatch (`spec.payload`, `spec.refs`), the runner
  advance (`spec.advance_on`) and the classification below. The claim and the mint are not in
  the pass at all: it CALLS `Loopctl.Delivery.Placement.place/4`, unchanged. The cron caller,
  `Loopctl.Workers.DispatchDriverWorker`, calls the dispatcher with the spec directly; this
  module keeps the driver-named entry points the suite, `Loopctl.Runners.Capacity` and the
  runbooks use, and the budget judgement (`normalise_budget/2`, `enabled?/0`) every pass reads.

  ## Selection

  FAIR ACROSS TENANTS, and across each tenant's PROJECTS: the read ranks each project's queue
  oldest first, then takes every project's oldest before any project's second, and every
  tenant's first before any tenant's second. One bound is shared by the whole fleet, so a
  plain global ordering let one tenant with a full queue consume every slot of every pass, and
  no other tenant's work was ever looked at. A plain oldest-first ranking within a tenant did
  the same one level down: whether a runner takes a repository is decided per story, after
  this read, so a project no runner accepts held the head of the queue for ever (2026-11-06).
  Oldest-first WITHIN a project is the part that cannot starve a story.

  A candidate must also be `pending` or `contracted` (#884): `Placement.place/4` contracts a
  `pending` one before it mints, so a triage-accepted story, a release whose re-contract did
  not land, and an escalation resolved to `queued` are all placed without an orchestrator.
  Any OTHER status behind a `queued` row (a stale row under a claimed story) is left out:
  selected on the stage alone it would be refused on every pass, its `updated_at` frozen and
  so permanently near the head of an oldest-first queue.

  ## Eligibility is decided BEFORE the claim, on all four facts

  A placement CLAIMS the story first and `Runners.dispatch/3` answers `:ok` the moment it
  broadcasts, so anything discovered after that point is not a refusal the driver can undo —
  it is a story stranded at `claimed` until its lease expires — a counted release that spends
  one of the story's attempts on a run that never happened. So a runner is eligible only when
  it is

    * CONNECTED (Phoenix Presence, keyed by machine name),
    * not DRAINING, accepts the story's REPO, and does the dispatch KIND — the three facts on
      its join meta, read through `Runners.accepts?/5`, which is the same rule `dispatch/3`
      applies rather than a second copy of it,
    * has a free slot on its row (`in_flight < max_sessions`) and its SUBSCRIPTION is not
      exhausted (US-44.6) — one query over the `runners` rows, `Loopctl.Runners.Selection`,
      which the triage dispatcher shares; a story left with no runner logs the tenant's
      exhausted runners and their earliest reset, once per tenant per pass, and
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

  alias Loopctl.Agents.Candidates
  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Specs.ImplementV1
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Runners.Runner

  @type outcome :: Dispatcher.build_outcome()

  @typedoc "A selected stage row: the three fields a pass reads, not the whole struct."
  @type candidate :: %{
          tenant_id: Ecto.UUID.t(),
          story_id: Ecto.UUID.t(),
          updated_at: NaiveDateTime.t()
        }

  @doc """
  The stories this pass will attempt, at most `limit`, fairly across tenants.

  `queued` AND `pending` or `contracted` AND with no unmet dependency (its own or its epic's,
  `Loopctl.WorkBreakdown.Dependencies`) AND under a project bound to exactly ONE active intake source —
  see the moduledoc on why the stage row alone selected released stories for ever, and why an
  unaddressable project is the same trap wearing the driver's own `:blocked` label. Ranked per
  project, then per tenant by that rank, and ordered by the tenant rank first: a tenant with one
  queued story is reached in the same pass as a tenant with two hundred, and a project with one
  in the same pass as a project with two hundred that no runner accepts.

  Fleet-wide and with no tenant in the predicate, exactly like the triage trigger's own
  candidate read — and carrying the same cost, which migration `20260921110000` documents for
  that one: a read on this shape with no supporting index sorts the whole table every pass.
  `story_stages_queued_idx` is its counterpart, keyed `(tenant_id, updated_at, story_id)`: it
  finds the `queued` rows in order. The per-project window then sorts only those rows, since the
  project is on `stories`, which is the queue's size and not the table's.

  ## Built from the spec (US-48.3)

  The read is `Loopctl.Agents.Candidates.query/2` over `implement@1`'s predicate list
  (`Loopctl.Agents.Specs.ImplementV1`): `{:stage, :queued}`,
  `{:agent_status_in, [:pending, :contracted]}` (`pending` too because `Placement` contracts a
  pending story before it mints, #884), `:dependencies_met`, `:single_active_source`,
  `:intake_record_optional` (an authored story has no record and stays a candidate) and
  `:issue_not_closed` (#1022), ranked `:round_robin_project_tenant` (#1019). Each predicate's
  reasoning lives on its clause in `Loopctl.Agents.Candidates`.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [candidate()]
  def candidates(limit) when is_integer(limit) and limit > 0 do
    ImplementV1.spec()
    |> Candidates.query(limit: limit)
    |> Loopctl.AdminRepo.all()
  end

  @doc """
  A runner of `tenant_id` that would accept an `implement` dispatch for `repo` right now, or
  `nil` — the FIRST of `available_runners/2`.

  Kept as the single-runner question because that is what most callers and every test asked;
  the placing path uses the list, for the reason `available_runners/2` gives.
  """
  @spec available_runner(Ecto.UUID.t(), String.t()) :: Runner.t() | nil
  def available_runner(tenant_id, repo) when is_binary(tenant_id) and is_binary(repo) do
    case available_runners(tenant_id, repo) do
      [runner | _] -> runner
      [] -> nil
    end
  end

  @doc """
  Every runner of `tenant_id` that would accept an `implement` dispatch for `repo` right now,
  in the order to try them.

  Every half of the moduledoc's eligibility rule, in the order that costs least: the tenant's
  admission headroom is one aggregate read and gates the whole pass for that tenant; the
  presence metas answer draining, repos and kind with no database at all; ONE row read answers
  capacity and exhaustion together (`Loopctl.Runners.Selection.runners/3`). Fewest slots
  first, so a fleet spreads rather than filling one machine.

  ## Why the PASS needs the list and not the head (846.2 review round 2, finding 3)

  `Runners.accepts?/5` knows nothing about `branch_prefixes`, so a machine whose declaration
  can produce no valid branch is still "accepting" — and is selected FIRST, because it is idle
  and this orders by fewest slots. Every story for that repository then failed
  `{:no_conforming_branch, _}` and the pass never reached the healthy second runner. One
  misconfigured box stopped delivery for a whole repository.

  Before contract 1.14.0 no placement could fail for a DECLARATION reason at all, so this is a
  new way for one machine to halt a queue rather than an old one this change exposes. The
  answer is to try the next candidate rather than to teach `accepts?/5` about prefixes: the
  derivation needs the STORY to know whether a prefix can produce a valid name, and
  `accepts?/5` is a per-runner predicate that has no story — a copy of the derivation there
  would be a second implementation of the thing story 846.2 exists to make singular.
  """
  @spec available_runners(Ecto.UUID.t(), String.t()) :: [Runner.t()]
  def available_runners(tenant_id, repo) when is_binary(tenant_id) and is_binary(repo),
    do: Dispatcher.runners(ImplementV1.spec(), tenant_id, repo)

  @doc """
  The budgets, or `{:error, {:unset, key}}` when either is missing: `implement@1`'s pair,
  `:dispatch_wall_clock_seconds` and `:dispatch_max_turns` (`Dispatcher.budgets/1`).

  NO DEFAULT, deliberately — see the moduledoc. Read once per pass and threaded, rather than
  per story, so a pass either has a policy or does not run at all.
  """
  @spec budgets() ::
          {:ok, Dispatcher.budgets()}
          | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def budgets, do: Dispatcher.budgets(ImplementV1.spec())

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
  defp budget_maximum(key)
       when key in [
              :dispatch_wall_clock_seconds,
              :triage_wall_clock_seconds,
              :spec_tune_wall_clock_seconds
            ],
       do: RunnerContract.RunnerDispatch.max_wall_clock_seconds()

  defp budget_maximum(key)
       when key in [:dispatch_max_turns, :triage_max_turns, :spec_tune_max_turns],
       do: :infinity

  @doc "True when an operator has turned the driver on. Defaults to FALSE."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:loopctl, :dispatch_driver_enabled, false) == true

  @doc """
  One pass: place what can be placed, and report what each candidate did —
  `Loopctl.Agents.Dispatcher.run/2` over `implement@1`.

  Returns `{:error, {:unset, key}}` rather than running when a budget is missing, and
  `{:ok, []}` when the driver is off — off is not a failure.
  """
  @spec run(pos_integer()) ::
          {:ok, [outcome()]} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def run(limit) when is_integer(limit) and limit > 0,
    do: Dispatcher.run(ImplementV1.spec(), limit: limit)

  @doc """
  The pass itself, on budgets already decided: what `run/1` does once both gates pass.

  Separate from `run/1` for the same reason `normalise_budget/2` is — the gates read
  application config, which a test may not set, so this is the only way the placing path is
  reachable from a test at all. `run/1` is the config decision; this is the work.

  The tenant-level facts a pass resolves (the operator key, whether the tenant's `:no_runner`
  note has been logged) are cached ACROSS candidates and the runner facts are not; see
  `Loopctl.Agents.Dispatcher` for why.
  """
  @spec run_with(pos_integer(), Dispatcher.budgets()) :: [outcome()]
  def run_with(limit, budgets) when is_integer(limit) and limit > 0 do
    {:ok, outcomes} =
      Dispatcher.run(ImplementV1.spec(), limit: limit, budgets: budgets, enabled?: true)

    outcomes
  end
end
