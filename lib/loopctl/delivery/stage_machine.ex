defmodule Loopctl.Delivery.StageMachine do
  @moduledoc """
  The per-story delivery stage machine as DATA (issue #803, design §3): the stages, the one
  allowed-transition table, and the facts derived from it. Pure — no database.

  Everything that decides whether a transition is legal reads `transitions/0`:
  `Loopctl.Delivery.Stages.advance/4` refuses anything absent from it, the migration's
  `story_stages_stage` CHECK is compared against `stages/0` by a test, and the transition
  test enumerates every `{from, to, edge}` triple from here rather than restating them.
  Adding an edge is one line in `@transitions`.

  ## Edges

  A transition is a triple `{from, to, edge}`. `:forward` is the main line:

      detected -> triaged -> queued -> claimed -> worktree -> implementing
               -> reviewing -> pr_open -> ci -> merged -> deployed -> verified -> done

  The failure edges are part of the machine, not exceptions to it, and are NAMED because
  two of them share a `{from, to}` pair (`ci -> implementing` is both a red CI run and a
  base that moved under a green one) and because each one counts in `attempts`:

  - `:ci_red` — ci -> implementing
  - `:review_findings` — reviewing -> implementing
  - `:base_moved` — merge conflict or base moved: pr_open | ci -> implementing
  - `:verification_failed` — post-deploy verification failing: deployed -> escalated
  - `:triage_escalate` — triaged -> escalated, the triage trio's `escalate` verdict
    (design §4), including the disagreement that escalates by construction
  - `:merge_gate` — ci -> escalated, the merge-precondition gate refusing (design §5:
    a clean result merges with no human, anything else routes to Gate A)
  - `:session_escalated` — any IN-FLIGHT stage -> escalated, the unattended session asking
    for Mark (design §8, "Escalation is a command the session calls"). The one escalation
    edge a session may take itself, and the only one available from the stages a runner
    holds: `:triage_escalate`, `:merge_gate` and `:verification_failed` are each a
    control-side verdict about a specific gate. Taken two ways, both of which end at this
    one edge so the chain entry is identical either way — `POST /stories/:id/escalate` from
    the claiming agent's own key, and a runner's `stage` message reporting what it read out
    of the run's `escalations.ndjson`.
  - `:merge_refused` — merged -> implementing, when the merge did not hold: a conflict, a
    branch protection rule, a required check. It needs a reason, it clears `merge_sha`
    along with the head, and it is CHAINED — the entry into `merged` is a custody fact, so
    retracting it writes a counter-entry rather than leaving the chain saying the story
    merged at a sha it did not
  - `:budget_exceeded` — any live stage -> failed
  - `:runner_lost` — an in-flight stage -> queued. Taken by the claim reclaimer
    (`Loopctl.Progress.reclaim_expired_claim/3`), never asked for by a runner: a runner
    that could report itself lost is not lost.
  - `:claim_released` — an in-flight stage -> queued, when the claim is released by
    unclaim, force-unclaim or a reject auto-reset. Also never asked for by a caller; see
    `Loopctl.Delivery.Stages.follow_release/5`.
  - `:human_resolution` — escalated -> queued | done | failed, and ONLY for a human
    principal (see `Loopctl.Delivery.Stages.advance/4`).

  `done` and `failed` are terminal; `escalated` is terminal except for `:human_resolution`.
  """

  @stages ~w(detected triaged queued claimed worktree implementing reviewing pr_open ci
             merged deployed verified done escalated failed)a

  @main_line ~w(detected triaged queued claimed worktree implementing reviewing pr_open ci
                merged deployed verified done)a

  # A runner holds the story in these, so its disappearance returns the story to the queue.
  # Nothing from `merged` on: the outward effect has already happened, and re-queueing a
  # merged story would merge it twice.
  @in_flight ~w(claimed worktree implementing reviewing pr_open ci)a

  @terminal ~w(done failed escalated)a

  @forward @main_line
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.map(fn [from, to] -> {from, to, :forward} end)

  @budget_exceeded for from <- @stages,
                       from not in @terminal,
                       do: {from, :failed, :budget_exceeded}

  @released for from <- @in_flight,
                edge <- [:runner_lost, :claim_released],
                do: {from, :queued, edge}

  @human_resolution for to <- [:queued, :done, :failed], do: {:escalated, to, :human_resolution}

  # The session's own escalation, from every stage a runner holds it in.
  @session_escalated for from <- @in_flight, do: {from, :escalated, :session_escalated}

  @transitions @forward ++
                 [
                   {:ci, :implementing, :ci_red},
                   {:reviewing, :implementing, :review_findings},
                   {:pr_open, :implementing, :base_moved},
                   {:ci, :implementing, :base_moved},
                   {:deployed, :escalated, :verification_failed},
                   {:triaged, :escalated, :triage_escalate},
                   {:ci, :escalated, :merge_gate},
                   {:merged, :implementing, :merge_refused}
                 ] ++ @budget_exceeded ++ @released ++ @human_resolution ++ @session_escalated

  # The part of the machine a RUNNER may report over the channel. Derived from
  # `@transitions`, so an edge added above is reportable or not by these rules rather than by
  # a second list somebody has to remember to extend. See `runner_transitions/0`.
  @runner_source_stages @in_flight ++ [:merged, :deployed, :verified]
  @runner_forbidden_edges [:runner_lost, :claim_released, :human_resolution]

  # The SOURCE filter is also what keeps `claimed` out as a destination: `queued` is the only
  # stage anything enters `claimed` from, and `queued` is not a source. A separate
  # `to != :claimed` clause was here and is gone — `bin/mutate.sh` returned exit 1 on it,
  # which is the tool saying no test can tell whether it is there. `stage_machine_test.exs`
  # asserts the property directly instead, so widening the source list to include `queued`
  # goes red rather than quietly handing a runner the transition that writes `runner_id` and
  # the claim's chain entry.
  @runner_transitions for {from, to, edge} <- @transitions,
                          from in @runner_source_stages,
                          edge not in @runner_forbidden_edges,
                          do: {from, to, edge}

  @runner_from_stages @runner_transitions |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  @runner_to_stages @runner_transitions |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  @runner_edges @runner_transitions |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  # The custody-critical transitions, and the only ones written to the audit chain (design
  # §11): a claim, a merge, an escalation, a human acting on one — and the RETRACTION of a
  # merge, because the chain already carries the merge as a fact and a retraction that is
  # not chained leaves it saying the story merged when it did not. The chain serialises
  # every writer in the tenant on its head row, so putting every stage change there would
  # serialise every concurrent story on that one row.
  @chained_targets [:claimed, :merged, :escalated]
  @chained_edges [:merge_refused]

  # Side-effect identities, and the stages allowed to write each one. A replayed stage finds
  # the identity its first run wrote; a writer from a stage that does not produce the effect
  # is refused, so a stale stage cannot record an identity for a later one.
  @effect_stages %{
    runner_id: [:claimed],
    worktree_path: [:worktree],
    branch: [:worktree],
    head_sha: [:implementing, :reviewing, :pr_open, :ci],
    pr_number: [:pr_open],
    # `merge_sha` is writable ONLY at `merged`, and only AFTER GitHub returns it. It is the
    # one identity that cannot be written before its effect, because the merge commit does
    # not exist until the merge happens: a value written at `ci` would be one the caller
    # never obtained. It is carried ON the transition —
    # `advance(…, {:ci, :merged}, effects: [merge_sha: sha])` — so the row and the
    # `story_stage_merged` chain entry are written in one transaction and the entry names
    # the merge it asserts. The merge's replay safety comes from `pr_number` + `head_sha`
    # instead: a resuming runner ASKS GitHub whether that head is already merged and adopts
    # the answer, rather than merging again and recording a second sha.
    merge_sha: [:merged],
    release_id: [:deployed]
  }

  # Identities that stop describing the story when an edge is taken, cleared by that edge.
  # Nothing is lost: every value was written to `story_stage_events` when it was recorded.
  # A lost runner's worktree is on a machine
  # nobody holds any more and its head may never have been pushed (a released claim's, the
  # same); the branch and the PR
  # live on GitHub and the next runner reuses them. Going back to implementing makes a new
  # head. A human re-queue starts over from nothing.
  @released_clears [:runner_id, :worktree_path, :head_sha]

  @type stage ::
          :detected
          | :triaged
          | :queued
          | :claimed
          | :worktree
          | :implementing
          | :reviewing
          | :pr_open
          | :ci
          | :merged
          | :deployed
          | :verified
          | :done
          | :escalated
          | :failed

  @type edge ::
          :forward
          | :ci_red
          | :review_findings
          | :base_moved
          | :verification_failed
          | :triage_escalate
          | :merge_gate
          | :merge_refused
          | :budget_exceeded
          | :runner_lost
          | :claim_released
          | :human_resolution
          | :session_escalated

  @type effect ::
          :runner_id
          | :worktree_path
          | :branch
          | :head_sha
          | :pr_number
          | :merge_sha
          | :release_id

  # `merge_sha` is written ONLY as part of the transition into `merged`, both ways round:
  # it is REQUIRED there (an entry asserting a merge must name it) and it is refused to
  # `record_effect/5` (recorded afterwards it would leave the chain saying the story merged
  # at nothing while the row named a sha the chain never saw). The two halves are one rule
  # and belong together — relaxing either reopens it.
  @transition_only [:merge_sha]
  @required_effects %{merged: [:merge_sha]}

  @type transition :: {stage(), stage(), edge()}

  @doc "Every stage, in main-line order followed by the off-line stages."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc "The complete allowed-transition table."
  @spec transitions() :: [transition()]
  def transitions, do: @transitions

  @doc "The stages a claim holds the story in — the sources of the release edges."
  @spec in_flight_stages() :: [stage()]
  def in_flight_stages, do: @in_flight

  @doc "`done`, `failed` and `escalated`."
  @spec terminal_stages() :: [stage()]
  def terminal_stages, do: @terminal

  @doc "True when `{from, to, edge}` is in the table."
  @spec allowed?(stage(), stage(), edge()) :: boolean()
  def allowed?(from, to, edge), do: {from, to, edge} in @transitions

  @doc "True for the edges only a human principal may take."
  @spec human_only?(edge()) :: boolean()
  def human_only?(edge), do: edge == :human_resolution

  @doc """
  The transitions a RUNNER may report over the channel (`stage`, contract 1.4.0), derived
  from `transitions/0` so the wire enum and the machine cannot drift.

  A runner may report only the part of the machine its own session drives, so three classes
  are held back and each for its own reason:

  - anything OUT OF a stage no session holds (`detected`, `triaged`, `queued`, `escalated`).
    Those are control's — triage and the human resolution — and a session that has been
    escalated away from is precisely the one that must not move the row back.
  - anything INTO `claimed`. That transition writes `runner_id` and a chain entry, and it is
    control's `advance(queued -> claimed)` alongside the claim itself; a runner reporting it
    would be naming its own machine as the story's holder.
  - `:runner_lost` and `:claim_released` (a runner that can report itself lost is not lost,
    and a release is the releasing transaction's — `Loopctl.Delivery.Stages.follow_release/5`)
    and `:human_resolution`, which is Mark's.

  `from` is on the wire and is part of the compare-and-set: a runner states the stage it
  believed the story was at, and a row that has moved refuses it rather than taking a
  transition from somewhere else.
  """
  @spec runner_transitions() :: [transition()]
  def runner_transitions, do: @runner_transitions

  @doc "True when `{from, to, edge}` is one a runner may report."
  @spec runner_reportable?(stage(), stage(), edge()) :: boolean()
  def runner_reportable?(from, to, edge), do: {from, to, edge} in @runner_transitions

  @doc "Every stage that appears as the SOURCE of a runner-reportable transition."
  @spec runner_from_stages() :: [stage()]
  def runner_from_stages, do: @runner_from_stages

  @doc "Every stage that appears as the TARGET of a runner-reportable transition."
  @spec runner_to_stages() :: [stage()]
  def runner_to_stages, do: @runner_to_stages

  @doc "Every edge a runner-reportable transition can carry."
  @spec runner_edges() :: [edge()]
  def runner_edges, do: @runner_edges

  @doc """
  True when arriving at `to` ENDS the session that was working the story, so the runner slot
  it held goes back (`Loopctl.Runners.DispatchLedger.release_slot_in/4`).

  DERIVED from the destination stage, never asserted by the caller. A message that could say
  "my session is over" while it ran would let a runner free a slot it is still using, and the
  admission ceiling it feeds is what keeps six concurrent sessions off one Anthropic account
  (design §9). `done`, `failed` and `escalated` are exactly the stages no session continues
  from: `escalated` waits on Mark, and the other two are terminal.
  """
  @spec ends_session?(stage()) :: boolean()
  def ends_session?(to), do: to in @terminal

  @doc "True for an edge counted in `attempts` — every edge except `:forward`."
  @spec counted?(edge()) :: boolean()
  def counted?(edge), do: edge != :forward

  @doc """
  True when the transition is custody-critical and is appended to the audit chain: into
  `claimed`, `merged` or `escalated`, out of `escalated`, or the `:merge_refused`
  retraction of a merge.
  """
  @spec chained?(stage(), stage(), edge()) :: boolean()
  def chained?(from, to, edge),
    do: to in @chained_targets or from == :escalated or edge in @chained_edges

  @doc "Every side-effect identity column."
  @spec effects() :: [effect()]
  def effects, do: Map.keys(@effect_stages)

  @doc """
  True for an identity that only a TRANSITION may write (`Loopctl.Delivery.Stages.advance/4`'s
  `:effects`), never `record_effect/5`: the merge sha, which a chained entry has to name.
  """
  @spec transition_only?(atom()) :: boolean()
  def transition_only?(effect), do: effect in @transition_only

  @doc """
  The identities a transition into `to` MUST carry. Entering `merged` without the sha would
  chain a merge that names nothing.
  """
  @spec required_effects(stage()) :: [effect()]
  def required_effects(to), do: Map.get(@required_effects, to, [])

  @doc "The stages allowed to record `effect`; `[]` for an unknown effect."
  @spec effect_stages(atom()) :: [stage()]
  def effect_stages(effect), do: Map.get(@effect_stages, effect, [])

  @doc "The identities a transition clears."
  @spec clears(stage(), stage(), edge()) :: [effect()]
  def clears(_from, :queued, edge) when edge in [:runner_lost, :claim_released],
    do: @released_clears

  def clears(:escalated, :queued, :human_resolution), do: Map.keys(@effect_stages)
  # A refused merge never happened, so the identity recorded for it goes with the head.
  def clears(:merged, :implementing, :merge_refused), do: [:head_sha, :merge_sha]
  def clears(_from, :implementing, edge) when edge != :forward, do: [:head_sha]
  def clears(_from, _to, _edge), do: []

  @doc """
  True when the transition requires a reason: entering `escalated` (the
  `story_stages_escalation_reason` CHECK enforces that half as well), and retracting a
  merge, whose chained counter-entry must say why the merge did not hold.
  """
  @spec reason_required?(stage(), edge()) :: boolean()
  def reason_required?(to, edge), do: to == :escalated or edge == :merge_refused
end
