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
  - `:triage_reject` — triaged -> failed, the triage trio's `reject` verdict (design §4):
    the report is genuinely non-actionable — a duplicate, or already covered by shipped
    behaviour. Its own edge and not `:budget_exceeded`, which shares the `{triaged, failed}`
    pair, because the two say opposite things to the person who reported the issue and
    `resolution_verdict/1` reads the EDGE to tell them apart: a reject closes her issue
    saying no change was needed, while a budget exhaustion closes nothing at all. A verdict
    somebody else reaches about the report, so it is not runner-reportable — `triaged` is
    not a runner source stage
  - `:merge_gate` — ci -> escalated, the merge-precondition gate refusing (design §5:
    a clean result merges with no human, anything else routes to Gate A)
  - `:session_escalated` — any in-flight stage, `merged` or `deployed` -> escalated: the
    unattended session asking for Mark (design §8, "Escalation is a command the session
    calls"). The one escalation edge a session may take itself, and the only one available
    from the stages a runner holds: `:triage_escalate`, `:merge_gate` and
    `:verification_failed` are each a control-side verdict about a specific gate. Taken two
    ways, both of which end at this one edge so the chain entry is identical either way —
    `POST /stories/:id/escalate` from the claiming agent's own key, and a runner's `stage`
    message reporting what it read out of the run's `escalations.ndjson`. It reaches past the
    in-flight stages because `merged` and `deployed` would otherwise be ABSORBING; see the
    comment above `@session_escalated`.
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

  # The `story_stages_text_bounds` CHECK on `escalation_reason`, in codepoints. See
  # `max_reason_length/0` for why it lives here and nowhere else.
  @max_reason_length 4_000

  # Where the RUNNER'S SESSION ends and its capacity slot goes back. The terminals, plus the
  # deploy — see `session_ends_at/0` for why those are not the same set.
  # `:triaged` ENDS A SESSION TOO, and leaving it out held a slot nobody was using. A triage
  # session stops the moment it states its verdict; `escalate` and `reject` land on terminal
  # stages and released correctly, while `story` — the COMMON case — stopped at `:triaged` and
  # left the triage dispatch's slot held on the runner until the lease reclaim swept it.
  #
  # No other session arrives here: `:triaged` is reached only by
  # `Loopctl.Delivery.TriageVerdict`, and the implement session that picks the story up later
  # holds its own dispatch and its own slot. So this ends the triage session without ending
  # the story, which is exactly what `session_ends_at/0` means.
  @session_ends_at @terminal ++ [:deployed, :triaged]

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

  # The session's own escalation. From every stage a runner holds the story in, and ALSO from
  # `merged` and `deployed` (#824 round 3, H2/3).
  #
  # Those two were absorbing. Narrowing the runner's source filter to stop at `merged` left
  # `deployed` with no edge out that anything in `lib/` can write: `RunnerStages` cannot (not
  # a source), `Escalations` builds `{row.stage, :escalated, :session_escalated}` which
  # existed only for `@in_flight`, `follow_release/5` and `follow_claim/4` only rebind, and
  # `:human_resolution` leaves `escalated` rather than reaching it. The moment a deploy was
  # reported the row froze for EVERY principal, Mark included.
  #
  # `merged` was nearly as bad: its only other edge is `:merge_refused`, which clears
  # `merge_sha` and CHAINS a retraction asserting the merge did not hold — a false custody
  # statement for "the deploy broke", and the only thing a caller could reach for.
  #
  # Escalating from either is now the way out, and it restores the human path
  # (`escalated -> queued | done | failed` over `:human_resolution`). `deployed -> verified`
  # stays for the control writer that does not exist yet; until it does, ESCALATION IS THE
  # ONLY WAY OUT OF `deployed`.
  @session_escalated for from <- @in_flight ++ [:merged, :deployed],
                         do: {from, :escalated, :session_escalated}

  @transitions @forward ++
                 [
                   {:ci, :implementing, :ci_red},
                   {:reviewing, :implementing, :review_findings},
                   {:pr_open, :implementing, :base_moved},
                   {:ci, :implementing, :base_moved},
                   {:deployed, :escalated, :verification_failed},
                   {:triaged, :escalated, :triage_escalate},
                   {:triaged, :failed, :triage_reject},
                   {:ci, :escalated, :merge_gate},
                   {:merged, :implementing, :merge_refused}
                 ] ++ @budget_exceeded ++ @released ++ @human_resolution ++ @session_escalated

  # The part of the machine a RUNNER may report over the channel: one definition, from which
  # `runner_transitions/0`'s doc, the wire enums and the published
  # `x-connection.stage_transitions` table all derive.
  #
  # It is an ALLOWLIST of edges, not a blocklist. Written as a blocklist it silently admitted
  # three transitions a session has no standing to assert — `:merge_gate`,
  # `:verification_failed` and `:budget_exceeded` — because none of them was on the list of
  # things to hold back. An allowlist fails the other way: a new edge is unreportable until
  # somebody decides it is a session's to report.
  #
  # The rule: a runner may report what its own session OBSERVED ABOUT ITS OWN WORK. Each of
  # these is something the session did or watched happen to its branch —
  #
  # - `:forward`, from `claimed` on: it made the worktree, wrote code, opened the PR, watched
  #   CI, merged, deployed, saw verification pass.
  # - `:ci_red`, `:review_findings`, `:base_moved`: its own run went red, its own review came
  #   back, its own base moved under it.
  # - `:merge_refused`: its own merge did not hold.
  # - `:session_escalated`: it is asking for Mark (design §8).
  #
  # and each of the three held back is a VERDICT SOMEBODY ELSE REACHES about the session:
  #
  # - `:merge_gate` — the merge-precondition gate (design §5). The gates compute their own
  #   triggers and OR them with an agent's signals, never reading an agent's negative; a
  #   runner able to report the gate's verdict could write a chain entry asserting a gate
  #   ruling that never ran.
  # - `:verification_failed` — post-deploy verification, which is control's comparison of the
  #   deployed sha against the merge commit (design §9), not something the session can see.
  # - `:budget_exceeded` — and this one is the worst of the three, because `failed` is
  #   terminal with NO way out, `:human_resolution` included. A runner able to report it can
  #   park a story for good with no path back. A session that has run out of budget escalates
  #   instead; control decides whether that is `failed`.
  #
  # THE SOURCE FILTER STOPS AT `merged`, and that is the other half of the rule (#824 round 2,
  # H1). With `deployed` and `verified` as sources the edge allowlist admitted
  # `deployed -> verified -> done` on `:forward`, so a session could drive its own story to
  # terminal success with no control-side verification — while `verification_failed` was held
  # back twelve lines above on the grounds that the check is CONTROL's. A session able to
  # report a check passing but not failing is worse than one able to report neither: nothing
  # else in `lib/` can write the negative (`RunnerStages` and `Escalations` are the only
  # callers of `Loopctl.Delivery.Stages.advance/4`), so the positive was the only outcome that
  # could ever be recorded.
  #
  # The line is at the DEPLOY because that is where the loop stops producing things control
  # can check and starts producing verdicts:
  #
  # - `merged` carries `merge_sha`, REQUIRED on that transition, and control can ask GitHub
  #   whether that sha is the merge commit. `deployed` carries `release_id`, likewise.
  # - `verified` and `done` carry nothing. Each is a pure verdict, and `verified`'s is
  #   specifically the sha comparison of design §9 that the session does not run.
  #
  # So: a runner may report what its own session did and control can independently check,
  # plus its own escalation, which stops the loop rather than advancing it. A story therefore
  # WAITS at `deployed` for control to decide verified-or-escalated, and no writer for that
  # exists yet — an unimplemented control path, chosen deliberately over a session certifying
  # itself.
  #
  # One residual asymmetry, named rather than hidden: `ci -> merged` is reportable while
  # `ci -> escalated` over `:merge_gate` is not, so the merge gate's positive outcome is a
  # runner's to report and its refusal is not. That is the checkability rule above and not an
  # oversight — a merge NAMES a sha GitHub can confirm, the gate's refusal names nothing —
  # but WHO PERFORMS THE MERGE is undecided in the design (§9 puts auto-merge last, and build
  # order step 1 merges nothing). Revisit this line when that is settled.
  #
  # The SOURCE filter is also what keeps `claimed` out as a destination: `queued` is the only
  # stage anything enters `claimed` from, and `queued` is not a source. A separate
  # `to != :claimed` clause was here and is gone — `bin/mutate.sh` returned exit 1 on it,
  # which is the tool saying no test can tell whether it is there. `stage_machine_test.exs`
  # asserts the property directly instead, so widening the source list to include `queued`
  # goes red rather than quietly handing a runner the transition that writes `runner_id` and
  # the claim's chain entry. The same test asserts every held-back edge and stage by name.
  @runner_source_stages @in_flight ++ [:merged]

  @runner_reportable_edges [
    :forward,
    :ci_red,
    :review_findings,
    :base_moved,
    :merge_refused,
    :session_escalated
  ]

  @runner_transitions for {from, to, edge} <- @transitions,
                          from in @runner_source_stages,
                          edge in @runner_reportable_edges,
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

  # Everything BOUND TO THE MERGE, cleared wherever `merge_sha` is. The same rule as
  # `@head_keyed` one identity along: post-deploy verification's unresolved count is kept
  # per MERGE (a sweep asks "is THIS merge deployed?"), so a count left behind after the
  # merge was retracted would escalate the next merge on its predecessor's blips.
  # `merge_keyed/0` is what the drift guard reads, so a new merge-bound field cannot be
  # added to one clause and forgotten in the others.
  @merge_keyed [:merge_sha, :post_deploy_unresolved]

  @released_clears [:runner_id, :worktree_path] ++ @head_keyed

  # Identities CONTROL writes, which a runner may therefore never carry on a `stage` message.
  # A LIST, not a single name, and that is the whole point: this was `-- [:runner_id]` when
  # `runner_id` was the only one, and #823 merging added `merge_gate_allowed_sha` to
  # `@effect_stages` — which silently made the MERGE GATE'S OWN ALLOW a reportable effect. A
  # runner reporting `pr_open -> ci` could then have carried the allow for its own head and
  # pre-authorised the gate that is supposed to judge it (#824, resolving the #823 merge).
  #
  # Neither is a thing a session does:
  #
  # - `runner_id` — written by the transition into `claimed`, which a runner may not report.
  #   Letting one name it would let it attribute a story to another machine.
  # - `merge_gate_allowed_sha` — written by `Loopctl.Delivery.MergePrecondition` at `ci`. It
  #   is the RECORD OF A VERDICT, and the same rule that keeps `:merge_gate` off the wire
  #   keeps its allow off too: a session may not report the outcome of a check it does not
  #   perform, and here it would not merely report it but GRANT it.
  #
  # Anything the gate writes in future goes here as well. The test in
  # `runner_contract_test.exs` binds this list to the wire schema in both directions, so a new
  # effect that belongs on neither side goes red rather than reaching a runner.
  @control_written_effects [:runner_id, :merge_gate_allowed_sha]

  @reportable_effects @effect_stages
                      |> Map.keys()
                      |> Kernel.--(@control_written_effects)
                      |> Enum.sort()

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
          | :triage_reject
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

  @doc """
  The longest `escalation_reason` or transition note, in CODEPOINTS — what Postgres
  `char_length` counts, not graphemes.

  THE one declaration of this bound (#824 round 2). It lived in four places plus prose, which
  is what CLAUDE.md's doc-hygiene rule forbids: a limit that is both enforced and documented
  references ONE attribute from every site. It is here, in the pure data module, because the
  machine is what both the enforcement (`Loopctl.Delivery.Stages`) and the two wire
  declarations (`Loopctl.ApiSpec.RunnerContract`,
  `LoopctlWeb.StoryEscalationController`) already depend on — and because how long a
  transition's reason may be is a fact about a transition.

  It mirrors the `story_stages_text_bounds` CHECK. Change one and the other is wrong;
  `Loopctl.Delivery.StagesTest` reads the constraint back from `pg_constraint`.
  """
  @spec max_reason_length() :: pos_integer()
  def max_reason_length, do: @max_reason_length

  # WHICH TRANSITIONS ARE A VERDICT THE REPORTER IS TOLD ABOUT (#805 item 1).
  #
  # Keyed on the whole TRANSITION, never on the destination stage, and that is the point of
  # it. Two of the three terminal stages are reachable by more than one route with different
  # meanings, so a stage cannot say what the reporter should be told:
  #
  # - `failed` is reached by `:triage_reject` (no change was needed — tell her) and by
  #   `:budget_exceeded` from every live stage (the loop ran out — tell her nothing, a human
  #   is looking).
  # - `done` is reached by `verified -> done` (the ordinary end of a shipped story, already
  #   accounted for one edge earlier) and by `escalated -> done` over `:human_resolution`,
  #   where a human has decided the outcome and loopctl has no verdict of its own to report.
  #
  # `{deployed, verified, :forward}` is the ONLY shipped verdict, and it is deploy-gated
  # rather than merge-gated on purpose: `Loopctl.Delivery.PostDeployVerification` writes that
  # edge, the merge is not the ship, and nothing at `merged` may tell a reporter a fix
  # shipped. Every `-> escalated` edge is deliberately absent: an escalated story is waiting
  # on a human, so there is no verdict yet and any close would claim the work is finished.
  @resolution_verdicts %{
    {:deployed, :verified, :forward} => :shipped,
    {:triaged, :failed, :triage_reject} => :not_actionable
  }

  @doc """
  The `Loopctl.Delivery.Resolution` verdict a transition implies, or `nil` for the transitions
  that tell the reporter nothing — which is almost all of them.

  Pure, and the single declaration of which edges reach the reporter. See the note above
  `@resolution_verdicts` for why this reads the whole transition rather than the destination
  stage.
  """
  @spec resolution_verdict(transition()) :: :shipped | :not_actionable | nil
  def resolution_verdict({_from, _to, _edge} = transition),
    do: Map.get(@resolution_verdicts, transition)

  @doc "Every transition that produces a resolution, with the verdict it produces."
  @spec resolution_transitions() :: %{transition() => :shipped | :not_actionable}
  def resolution_transitions, do: @resolution_verdicts

  @doc "True when `{from, to, edge}` is in the table."
  @spec allowed?(stage(), stage(), edge()) :: boolean()
  def allowed?(from, to, edge), do: {from, to, edge} in @transitions

  @doc "True for the edges only a human principal may take."
  @spec human_only?(edge()) :: boolean()
  def human_only?(edge), do: edge == :human_resolution

  @doc """
  The transitions a RUNNER may report over the channel (`stage`, contract 1.4.0).

  **A runner may report what its own session DID AND CONTROL CAN INDEPENDENTLY CHECK, plus
  its own escalation. Never the outcome of a check it does not perform.** That is the
  definition; the set is derived from `transitions/0` by two filters over
  `runner_source_stages/0` and `runner_reportable_edges/0`, so the wire enums, the contract's
  published `x-connection.stage_transitions` table and this doc cannot drift from each other
  or from the machine.

  Both filters are ALLOWLISTS, and each holds back one half of the rule. The EDGES exclude
  the verdicts another principal reaches (`merge_gate`, `verification_failed`,
  `budget_exceeded`). The SOURCES stop at `merged`, which is where the loop stops producing
  things control can check — `merged` and `deployed` name a sha and a release id GitHub can
  confirm, while `verified` and `done` name nothing and are pure verdicts. A story WAITS at
  `deployed` for control. Read the comment above `@runner_transitions` for the case that
  forced this and for the one residual asymmetry it leaves.

  `from` is on the wire and is part of the compare-and-set: a runner states the stage it
  believed the story was at, and a row that has moved refuses it rather than taking a
  transition from somewhere else.
  """
  @spec runner_transitions() :: [transition()]
  def runner_transitions, do: @runner_transitions

  @doc """
  The stages a runner may report a transition OUT of: the ones its session holds the story in,
  plus `merged` — the last one it drives, because reporting the deploy is the last thing a
  session does. See the comment above `@runner_transitions` for why the list stops there.
  """
  @spec runner_source_stages() :: [stage()]
  def runner_source_stages, do: @runner_source_stages

  @doc """
  The edges a runner may report: the ALLOWLIST half of `runner_transitions/0`. Everything
  else is a verdict some other principal reaches about the session — see the comment above
  `@runner_transitions`.
  """
  @spec runner_reportable_edges() :: [edge()]
  def runner_reportable_edges, do: @runner_reportable_edges

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
  The stages at which the RUNNER'S SESSION is over, so its capacity slot goes back
  (`Loopctl.Runners.DispatchLedger.release_slot_in/4`).

  **The session ending is not the story ending, and conflating them leaked slots on the
  SUCCESS path** (#824 round 3, H1). The terminals alone were the set, which was right while a
  runner could report through `verified -> done`; once the source filter stopped at `merged`
  the last thing a session reports is the DEPLOY, and `deployed` is not terminal — so a
  successful run released nothing inline and its slot waited out `heal/3`'s wall-clock bound.
  That bound is the dispatch's whole budget, so a ten-minute session held a slot for an hour,
  a two-session machine sat at capacity for the rest of it, and the tenant ceiling counted the
  phantom. The only inline release a runner could still trigger was the FAILURE path.

  So the set is the terminals plus `deployed`: every stage from which this runner's session
  does no more work. The story continues from `deployed` — it waits on control for
  `verified` — which is exactly the distinction.
  """
  @spec session_ends_at() :: [stage()]
  def session_ends_at, do: @session_ends_at

  @doc """
  True when arriving at `to` ends the session (`session_ends_at/0`).

  DERIVED from the destination stage, never asserted by the caller. A message that could say
  "my session is over" while it ran would let a runner free a slot it is still using, and the
  admission ceiling it feeds is what keeps six concurrent sessions off one Anthropic account
  (design §9). Both release paths read THIS — `Loopctl.Delivery.Stages`' inline release and
  `Loopctl.Delivery.RunnerStages`' replay release — so they cannot disagree about when a
  session ended.
  """
  @spec ends_session?(stage()) :: boolean()
  def ends_session?(to), do: to in @session_ends_at

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

  @doc """
  The columns BOUND TO THE MERGE: cleared together, everywhere `merge_sha` is.

  `post_deploy_unresolved` is a counter, which `record_effect/5` cannot hold, so this is a
  separate list from `effects/0` for the same reason `head_keyed/0` is; the drift guard in
  `stage_machine_test.exs` keeps a new one from being added to a single clause.
  """
  @spec merge_keyed() :: [atom()]
  def merge_keyed, do: @merge_keyed

  @doc "Every side-effect identity column."
  @spec effects() :: [effect()]
  def effects, do: Map.keys(@effect_stages)

  @doc """
  The identities a RUNNER may carry on a `stage` message, and the ones echoed back to it:
  every effect except those CONTROL writes (`control_written_effects/0`).

  One declaration, so the contract's `RunnerStage` properties, the `stage` ack and the
  `effect_conflict` refusal all name the same set; `runner_contract_test.exs` asserts the
  schema against it in both directions. Read the comment above `@control_written_effects` for
  what is held back and why — and for the case that turned it from one name into a list.
  """
  @spec reportable_effects() :: [effect()]
  def reportable_effects, do: @reportable_effects

  @doc """
  The identities CONTROL writes, which a runner may never carry. See the comment above
  `@control_written_effects`; anything the merge gate writes in future belongs here.
  """
  @spec control_written_effects() :: [effect()]
  def control_written_effects, do: @control_written_effects

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

  # A human re-queue starts over from nothing, so it clears the head-keyed and merge-keyed
  # fields too — neither counter is an effect, so `Map.keys(@effect_stages)` does not
  # include them, and leaving one standing would escalate the resolved story again on the
  # first blip at the same commit.
  def clears(:escalated, :queued, :human_resolution),
    do: Enum.uniq(Map.keys(@effect_stages) ++ @head_keyed ++ @merge_keyed)

  # A refused merge never happened, so the identity recorded for it goes with the head —
  # and so does everything keyed to that merge.
  def clears(:merged, :implementing, :merge_refused), do: @merge_keyed ++ @head_keyed

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
