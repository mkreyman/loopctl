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
                   {:deployed, :escalated, :verification_failed}
                 ] ++ @budget_exceeded ++ @released ++ @human_resolution

  # The custody-critical transitions, and the only ones written to the audit chain (design
  # §11): a claim, a merge, an escalation, and a human acting on one. The chain serialises
  # every writer in the tenant on its head row, so putting every stage change there would
  # serialise every concurrent story on that one row.
  @chained_targets [:claimed, :merged, :escalated]

  # Side-effect identities, and the stages allowed to write each one. A replayed stage finds
  # the identity its first run wrote; a writer from a stage that does not produce the effect
  # is refused, so a stale stage cannot record an identity for a later one.
  @effect_stages %{
    runner_id: [:claimed],
    worktree_path: [:worktree],
    branch: [:worktree],
    head_sha: [:implementing, :reviewing, :pr_open, :ci],
    pr_number: [:pr_open],
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
  `claimed`, `merged` or `escalated`, or out of `escalated`.
  """
  @spec chained?(stage(), stage()) :: boolean()
  def chained?(from, to), do: to in @chained_targets or from == :escalated

  @doc "Every side-effect identity column."
  @spec effects() :: [effect()]
  def effects, do: Map.keys(@effect_stages)

  @doc "The stages allowed to record `effect`; `[]` for an unknown effect."
  @spec effect_stages(atom()) :: [stage()]
  def effect_stages(effect), do: Map.get(@effect_stages, effect, [])

  @doc "The identities a transition clears."
  @spec clears(stage(), stage(), edge()) :: [effect()]
  def clears(_from, :queued, edge) when edge in [:runner_lost, :claim_released],
    do: @released_clears

  def clears(:escalated, :queued, :human_resolution), do: Map.keys(@effect_stages)
  def clears(_from, :implementing, edge) when edge != :forward, do: [:head_sha]
  def clears(_from, _to, _edge), do: []

  @doc """
  True when the transition requires an `escalation_reason` — entering `escalated`. Enforced
  by the `story_stages_escalation_reason` CHECK as well.
  """
  @spec reason_required?(stage()) :: boolean()
  def reason_required?(to), do: to == :escalated
end
