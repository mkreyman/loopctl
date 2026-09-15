defmodule Loopctl.Delivery.Completion do
  @moduledoc """
  The last transition of the delivery loop: `verified -> done` (issue #803 §3).

  ## The defect this closes

  Nothing in `lib/` wrote this edge. A story that passed every gate — triaged, queued,
  claimed, implemented, reviewed, merged, deployed and VERIFIED — stopped one stage from the
  end of the line and stayed there for ever, because `verified` had no writable edge out at
  all: it is not a runner source stage (`StageMachine.runner_source_stages/0` stops at
  `merged`), it is not in the `@session_escalated` set, and `:human_resolution` LEAVES
  `escalated` rather than reaching it. Not even an operator could move it.

  That is the same defect as `triaged -> queued` (#847) and it is the same shape the comment
  above `@session_escalated` records for `merged` and `deployed`: an ABSORBING stage, reached
  by narrowing one writer's source filter without asking what then writes the next edge. It
  moved one stage forward each time a writer was added, and this is the end of the line, so
  there is nowhere left for it to move to.

  ## What `done` MEANS, and why it is not the same fact as `verified`

  They are two different statements and the loop needs both:

  - `verified` — the deploy was checked and it shipped. `StageMachine.resolution_verdict/1`
    maps `{:deployed, :verified, :forward}` to `:shipped`, and `Stages.advance/4` writes the
    `intake_issue_closures` outbox row in that same transaction. So at `verified` the
    REPORTER HAS BEEN PROMISED SOMETHING and nothing has been said to them yet.
  - `done` — every outward obligation is discharged. Nothing further will happen to this
    story, which is exactly what `Stages.live_row/2` means when it excludes `[:done, :failed]`
    from every claim and release.

  Collapsing them would mean either telling the reporter nothing (drop the outbox) or calling
  a story finished while an unsent GitHub comment sits in a queue. The gap between the two is
  a real interval — the drainer retries a transient forge fault with backoff — and it is
  precisely the interval during which "is this finished?" has the answer NO.

  ## The settlement rule, and the class it must not strand

  A story at `verified` is `done` when its closure obligation is settled, which is EITHER:

  - its `intake_issue_closures` row is `:closed` — loopctl told the reporter, and nothing
    reopens a closed row; or
  - **there is no row at all**, because the story came from no intake record and therefore
    owed the reporter nothing. `record_issue_closure/3` writes a row only for a story with an
    `intake_record_id`, and a backfill or an API-created story has none.

  **That second clause is the whole reason this is not simply "the drainer marks it done".**
  Keying completion on the closure row alone reintroduces the defect one layer down: every
  non-intake story would sit at `verified` for ever, and the sweep would report a clean run
  while doing it. A rule that only handles the case you were thinking about is how this stage
  became absorbing in the first place.

  ## `:abandoned` DOES NOT SETTLE, and that is review round 1's correction

  It looks terminal — the drainer gave up and left the row for a person — and the first
  version of this module settled on exactly that reading. Wrong, because
  `IssueClosures.requeue_abandoned/1` exists: an operator who fixes the cause (the standing
  case is a `GITHUB_TOKEN` missing `issues: write`, which abandons every closure in its window
  on the first attempt) puts those rows back to `:pending`, and the drainer then really does
  post the comments and close the issues.

  `done` is TERMINAL and excluded from `Stages.live_row/2`, so there is no walking it back.
  Settling on `:abandoned` therefore meant: a misconfigured token abandons forty closures,
  this sweep marks all forty stories `done` inside a minute, the operator fixes the token an
  hour later, and forty reporters are told about work loopctl has already recorded as fully
  discharged — with the machine unable to say otherwise. When the target stage cannot be left,
  the conservative direction is the only safe one.

  So an abandoned closure WAITS, exactly as a pending one does. That is not a stranded story:
  the obligation is genuinely outstanding, `verified` is the honest place to rest while it is,
  and one `requeue_abandoned/1` plus a drain moves it. The stage is not ABSORBING — it has a
  writer — which is the property that matters and the one this module exists for.

  A `:pending` row is unsettled for the plainer reason: the drainer is working, or is backing
  off. Neither is an error and nothing is logged at error for them; the next sweep asks again.

  ## Where the state lives, and what a restart costs

  Postgres, like every other stage decision. This module owns no process, caches nothing and
  holds no connection across anything. `Loopctl.Workers.StoryCompletionWorker` is the caller
  because by `verified` THE SESSION ENDED LONG AGO — `deployed` is in
  `StageMachine.session_ends_at/0` — so there is no runner left to report anything and no
  endpoint anyone would poll. A node that dies mid-sweep loses nothing: the next sweep on any
  node re-reads the same rows.

  ## Retries

  `complete/3` is safe to repeat. The write is `Stages.advance/4`'s compare-and-set from
  `verified`, so a second sweep over a story the first already completed finds the row at
  `done` and is refused `:stale_stage` — which this module reports as `{:error, :stale_stage}`
  and the worker logs at info, never as a failure. Two nodes sweeping the same batch resolve
  the same way: both write the one row and exactly one commits.

  ## The epoch

  The transition is fenced on the story's `claim_epoch`, read from the stage row rather than
  supplied by the caller. Nothing holds a claim at `verified` — the session ended at
  `deployed` — so there is no zombie to fence against here; the epoch is passed because
  `advance/4` requires it and because a story whose epoch moved under the sweep is one
  something else is doing work on, and this sweep should lose that race rather than win it.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.IssueClosure

  @transition {:verified, :done, :forward}

  @doc """
  Stories at `verified` whose closure obligation is settled, oldest first, fair across tenants.

  The settlement predicate is IN THE QUERY rather than discovered per story, for the reason
  `DispatchDriver` and `TriageDispatcher` both record: a story this sweep cannot complete
  keeps its `updated_at` where it is, so a candidate set that included the unsettled ones
  would put them at the head of an oldest-first ranking for ever and a batch of them would
  starve every story behind.

  Public so the selection is falsifiable rather than buried in the pass.
  """
  @spec candidates(pos_integer()) :: [
          %{tenant_id: Ecto.UUID.t(), story_id: Ecto.UUID.t(), claim_epoch: integer()}
        ]
  def candidates(limit) when is_integer(limit) and limit > 0 do
    # UNSETTLED, not "has a row": a story with NO row owes nothing and is settled by having
    # nothing to do. The anti-join below is what carries that — an unsettled row excludes its
    # story, and the absence of a row does not.
    #
    # `!= :closed` rather than `== :pending`, which is round 1's correction: `:abandoned` is
    # REOPENABLE by `IssueClosures.requeue_abandoned/1`, and `done` cannot be walked back. See
    # the moduledoc.
    unsettled =
      from c in IssueClosure,
        where: c.status != :closed,
        select: %{tenant_id: c.tenant_id, story_id: c.story_id}

    ranked =
      from s in StoryStage,
        left_join: u in subquery(unsettled),
        on: u.tenant_id == s.tenant_id and u.story_id == s.story_id,
        where: s.stage == :verified,
        where: is_nil(u.story_id),
        select: %{
          tenant_id: s.tenant_id,
          story_id: s.story_id,
          claim_epoch: s.claim_epoch,
          updated_at: s.updated_at,
          rank:
            over(row_number(),
              partition_by: s.tenant_id,
              order_by: [asc: s.updated_at, asc: s.story_id]
            )
        }

    AdminRepo.all(
      from r in subquery(ranked),
        order_by: [asc: r.rank, asc: r.updated_at, asc: r.story_id],
        limit: ^limit,
        select: %{tenant_id: r.tenant_id, story_id: r.story_id, claim_epoch: r.claim_epoch}
    )
  end

  @doc """
  Takes `verified -> done` for one story, fenced on `claim_epoch`.

  `{:ok, row}` when it committed. `{:error, :stale_stage}` when the row is no longer at
  `verified` — another sweep completed it, or something moved it — which is a normal outcome
  of two nodes sweeping and never a failure. Every other `Stages.advance/4` refusal passes
  through under its own name.

  It re-checks the settlement rule rather than trusting the candidate row. Round 1 of review
  corrected WHICH race that closes, and the correction is worth keeping because the first
  answer was the reassuring one:

  - a FRESH closure row cannot appear for a story sitting at `verified`. `resolution_verdict/1`
    maps only `{:deployed, :verified, :forward}` and `{:triaged, :failed, :triage_reject}`, and
    `verified`'s own edges out are both terminal, so nothing can write one.
  - what CAN happen is `IssueClosures.requeue_abandoned/1` turning a settled row unsettled
    while the batch is in flight. The re-check narrows that window to the microseconds between
    it and the commit; it does not close it, because `unsettled_closure?/2` runs outside
    `Stages.advance/4`'s transaction and nothing locks the closure row.

  That residue is accepted deliberately rather than overlooked. Closing it would mean taking
  the closure row `FOR UPDATE` inside the stage transaction — a second table in a transaction
  that already holds the story row and appends to the tenant's audit chain, for a race whose
  loser is one story completing a few milliseconds before an operator's requeue. The operator
  sees it in the requeue's own count, and the reporter still gets the comment, because
  `IssueClosures.due/1` has no stage predicate and drains the row whatever stage its story
  reached. What the FIRST version got wrong was not this window; it was settling on
  `:abandoned` at all, which made the same operator action wrong for an entire batch rather
  than for a microsecond.
  """
  @spec complete(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | {:waiting, :closure_unsettled}
  def complete(tenant_id, story_id, opts \\ []) do
    if unsettled_closure?(tenant_id, story_id) do
      {:waiting, :closure_unsettled}
    else
      Stages.advance(tenant_id, story_id, @transition,
        claim_epoch: Keyword.fetch!(opts, :claim_epoch),
        actor_label: Keyword.get(opts, :actor_label, "worker:story_completion"),
        # A worker holding no credential. `:agent` keeps the human-only edges out of reach
        # whatever the default becomes, and the empty lineage is stated rather than absent
        # because `advance/4` reads an absent one as a caller that forgot to resolve it.
        actor_role: :agent,
        actor_lineage: []
      )
    end
  end

  @doc """
  The transition this module writes, so a test names it from here rather than restating it.
  """
  @spec transition() :: {atom(), atom(), atom()}
  def transition, do: @transition

  defp unsettled_closure?(tenant_id, story_id) do
    AdminRepo.exists?(
      from c in IssueClosure,
        where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
        where: c.status != :closed
    )
  end
end
