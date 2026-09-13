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
                 ] ++ @budget_exceeded ++ @released ++ @human_resolution

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
    release_id: [:deployed],
    # Not an effect the loop performs — the record that one was AUTHORISED (#803, review
    # round 1). `Loopctl.Delivery.MergePrecondition` writes the head sha it allowed, at
    # `ci`, so an already-merged pull request whose head carries no allow is escalated as
    # an ungated merge rather than reported clean. It is here rather than in a table of its
    # own because it is bound to the head like every other identity, and because
    # `record_effect/5`'s idempotence is exactly the semantics an allow needs: the same
    # head twice is the same allow, and a DIFFERENT head is `:effect_conflict` rather than
    # a silent re-grant.
    merge_gate_allowed_sha: [:ci]
  }

  # Identities that stop describing the story when an edge is taken, cleared by that edge.
  # Nothing is lost: every value was written to `story_stage_events` when it was recorded.
  # A lost runner's worktree is on a machine
  # nobody holds any more and its head may never have been pushed (a released claim's, the
  # same); the branch and the PR
  # live on GitHub and the next runner reuses them. Going back to implementing makes a new
  # head. A human re-queue starts over from nothing.
  # Everything BOUND TO THE HEAD, cleared wherever `head_sha` is. An allow is granted for a
  # head, and the merge gate's unevaluated count is kept per head, so either one left behind
  # would speak for a head that no longer exists: the allow would authorise an unjudged
  # commit, and the count would escalate a fresh head on its predecessor's blips.
  # `head_keyed/0` is what the drift guard reads, so a new head-bound field cannot be added
  # to one clause and forgotten in the others.
  @head_keyed [:head_sha, :merge_gate_allowed_sha, :merge_gate_unevaluated]

  @released_clears [:runner_id, :worktree_path] ++ @head_keyed

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

  @type effect ::
          :runner_id
          | :worktree_path
          | :branch
          | :head_sha
          | :pr_number
          | :merge_sha
          | :release_id
          | :merge_gate_allowed_sha

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

  @doc """
  The columns BOUND TO THE HEAD: cleared together, everywhere `head_sha` is cleared.

  Not all of them are side-effect identities — `merge_gate_unevaluated` is a counter, which
  `record_effect/5` cannot hold — so this is a separate list, and the drift guard in
  `stage_machine_test.exs` is what keeps a new one from being added to a single clause.
  """
  @spec head_keyed() :: [atom()]
  def head_keyed, do: @head_keyed

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

  # A human re-queue starts over from nothing, so it clears the head-keyed fields too —
  # `merge_gate_unevaluated` is not an effect, so `Map.keys(@effect_stages)` does not
  # include it, and leaving the count standing would escalate the resolved story again on
  # the first blip at the same commit.
  def clears(:escalated, :queued, :human_resolution),
    do: Enum.uniq(Map.keys(@effect_stages) ++ @head_keyed)

  # A refused merge never happened, so the identity recorded for it goes with the head.
  def clears(:merged, :implementing, :merge_refused), do: [:merge_sha | @head_keyed]

  def clears(_from, :implementing, edge) when edge != :forward, do: @head_keyed

  def clears(_from, _to, _edge), do: []

  @doc """
  True when the transition requires a reason: entering `escalated` (the
  `story_stages_escalation_reason` CHECK enforces that half as well), and retracting a
  merge, whose chained counter-entry must say why the merge did not hold.
  """
  @spec reason_required?(stage(), edge()) :: boolean()
  def reason_required?(to, edge), do: to == :escalated or edge == :merge_refused
end
