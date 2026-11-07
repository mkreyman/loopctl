defmodule Loopctl.Delivery.TriageDispatcher do
  @moduledoc """
  Sends a TRIAGE dispatch for every story the loop has just detected (issue #803 §4).

  This is the hop that was missing between intake and everything else. `TriageTrigger` turns a
  reported issue into a story at `detected`; `TriageVerdict` applies a verdict when one comes
  back; `DispatchDriver` places stories at `queued`. Nothing asked a runner to do the triage in
  between — `dispatchable_kinds` did not include `triage` (contract 1.10.0 adds it) and nothing
  in `lib/` built the dispatch. So the trio ran only where a person ran it, and a real ticket
  stopped at `detected` for ever.

  ## The pass runs from `triage@1` (US-48.4)

  Every function here is `Loopctl.Agents.Dispatcher` over `Loopctl.Agents.Specs.TriageV1`:
  the candidates, the payload (`:fenced_intake_report`), the refs (`:source_base_branch` for both
  `branch` and `base_branch`), the too-large escalation (the `:payload_too_large` screen), the
  transient/blocked classification and the `:stranded_triaged_unbound` sweep. The cron caller,
  `Loopctl.Workers.TriageDispatchWorker`, calls the dispatcher with the spec directly; this
  module keeps the triage-named entry points the suite and the runbooks use.

  ## It claims NOTHING, and that is the difference from `Placement.place/4`

  An implement dispatch claims the story: the session works on it, and the claim is what the
  custody gates compare against. A triage session READS — the reporter's words and the
  repository — and produces a judgement. Claiming for it would mark the story as being worked
  by the machine that is only deciding whether it is work at all, and would put it at
  `claimed`, which is the stage an implement session reports from.

  The dispatch carries the story's CURRENT `claim_epoch` instead, which is what the ledger
  fences against and what the verdict's transitions are checked on when it comes back. That is
  the `:judge` archetype, and `Loopctl.Agents.Dispatcher.run/2` runs no other.

  ## Eligibility, and why triage is stricter about the runner than implement is

  `Loopctl.Runners.Selection.runners/3` decides, the selection the driver makes too: connected,
  not draining, the repository declared, the KIND declared (`Runners.accepts?/5`, the reader
  `Runners.dispatch/3` uses), a free slot and a subscription that is not exhausted (US-44.6) —
  all BEFORE the ledger row is written, since a refusal discovered after it is a spent
  `dispatch_id` and a slot returned, once per story per pass. The kind half matters
  more here than anywhere else, because `Kinds.implied_by_silence/0` stays `implement` alone —
  a runner built before the `kinds` field existed is never sent triage, and only a machine that
  says `triage` on join receives one. That asymmetry is what makes 1.10.0 safe to deploy ahead
  of the fleet, and this module must never widen it.

  ## Budgets

  Its own, and unset by default like the driver's: a triage session reads a ticket and answers,
  so it is a fraction of an implement run, and inheriting the implement budgets would hand a
  reading session a day of wall clock. `:triage_wall_clock_seconds` and `:triage_max_turns`
  (the spec's `budgets` pair) have NO DEFAULT for the reason `DispatchDriver` states: a default
  here is loopctl's guess quietly becoming the operator's cost policy.

  ## What it does NOT do

  Retry or remember. A story it could not dispatch stays at `detected` and is a candidate
  again next pass — the same shape as the triage trigger and the driver, for the same reason:
  the condition either clears on its own (no runner declaring `triage` yet) or needs a person.

  What stops a SECOND dispatch going out for a story already being triaged is `candidates/1`,
  which excludes any story holding an unreleased triage dispatch. The `dispatch_id` itself is
  generated fresh per attempt, like the driver's; see the comment above
  `Loopctl.Agents.Dispatcher`'s payload builder for why deriving it from the story blocked
  re-triage permanently.

  A story it can never dispatch does NOT sit here silently. `:triage_too_large` — a ticket
  whose rendered object will not fit the contract's bound — is ESCALATED, because it is the
  one refusal in this pass that needs a person rather than time, and `TriagePayload` says so
  in its own moduledoc. The two `:blocked` shapes that remain are a project with no single
  intake source and a record that has gone: neither is a candidate at all (the first is
  excluded by the query, the second logs and is rare), so neither can head-of-line the queue.
  """

  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Specs.TriageV1

  @type outcome :: Dispatcher.outcome()

  @doc """
  Stories at `detected` that came from an intake record, are under a project bound to exactly
  one intake source, and have no triage session already running — oldest first within a
  project, round-robin across a tenant's projects, fair across tenants.

  The intake record is required rather than optional: the triage payload IS the reporter's
  words, so a story with no record has nothing to triage and would be dispatched with an empty
  object. Those exist — a backfill, a story created through the API — and they are not this
  loop's work.

  ## The two predicates that are here rather than discovered per story

  BOTH close the same trap, which `DispatchDriver`'s own moduledoc records as a defect it
  already paid for: nothing removes a dispatched triage story from this set — no claim is
  taken and no stage row is written until the verdict lands — so a story this pass cannot
  dispatch keeps its `updated_at` frozen at detection time and sits at the HEAD of an
  oldest-first ranking for ever. Twenty of them fill every batch while the worker reports a
  clean run.

  - **One active intake source.** A project with none has no repository and a project with two
    names no single one, so every story under it is `:blocked` permanently. The same predicate,
    for the same reason, as the driver's.
  - **No unreleased triage dispatch.** This is what replaced a `dispatch_id` DERIVED from the
    story and its epoch. That derivation made a second pass during a live session harmless, and
    bought it with two permanent blocks: nothing bumps `claim_epoch` on an unclaimed `detected`
    story, so the id could never differ — a runner that took the dispatch and then went away
    left `:dispatch_id_conflict` against the next runner for ever, and one that ACCEPTED and
    then died without a verdict left `:dispatch_already_replied` for ever, logged at `info` as
    though the fleet were merely busy. The ledger row is the better answer to the same
    question, because it is the thing that ENDS: `Loopctl.Runners.Capacity.heal/3` releases a
    reservation whose session outran its wall clock, so a dead triage session stops excluding
    its story and the next pass sends a fresh dispatch.

  ## Built from the spec (US-48.3)

  The read is `Loopctl.Agents.Candidates.query/2` over `triage@1`'s predicate list
  (`Loopctl.Agents.Specs.TriageV1`): `{:stage, :detected}`, `:intake_record_required`,
  `:single_active_source`, `:no_live_dispatch_of_self`, `:requires_ticket_if_source_says`
  (#1018) and `:issue_not_closed` (#1022), ranked `:round_robin_project_tenant` (#1019). Each
  predicate's reasoning lives on its clause in `Loopctl.Agents.Candidates`.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [Dispatcher.candidate()]
  def candidates(limit) when is_integer(limit) and limit > 0,
    do: Dispatcher.candidates(TriageV1.spec(), limit)

  @doc "The budgets a triage session runs under, or `{:error, {:unset, key}}`."
  @spec budgets() ::
          {:ok, Dispatcher.budgets()}
          | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def budgets, do: Dispatcher.budgets(TriageV1.spec())

  @doc """
  One pass: ask a runner to triage what has been detected.

  Behind the SAME switch as the driver (`:dispatch_driver_enabled`) on purpose. Two flags
  would make "the loop runs unattended" a state an operator can be half in — triage running
  while nothing places the result, or the reverse — and the thing being authorised is the
  same: sessions started on someone's machines with nobody watching.
  """
  @spec run(pos_integer()) ::
          {:ok, [outcome()]} | {:error, {:unset, atom()} | {:over_contract_maximum, atom()}}
  def run(limit) when is_integer(limit) and limit > 0,
    do: Dispatcher.run(TriageV1.spec(), limit: limit)

  @doc "The pass itself, on budgets already decided — the seam a test can reach."
  @spec run_with(pos_integer(), Dispatcher.budgets()) :: [outcome()]
  def run_with(limit, budgets) when is_integer(limit) and limit > 0 do
    {:ok, outcomes} =
      Dispatcher.run(TriageV1.spec(), limit: limit, budgets: budgets, enabled?: true)

    outcomes
  end

  @doc """
  Stories the too-large route left HALF-TAKEN: `triage@1`'s `:stranded_triaged_unbound`
  sweep (`Loopctl.Agents.Dispatcher.swept/3`).
  """
  @spec stranded(pos_integer()) :: [Dispatcher.candidate()]
  def stranded(limit) when is_integer(limit) and limit > 0,
    do: Dispatcher.swept(TriageV1.spec(), :stranded_triaged_unbound, limit)
end
