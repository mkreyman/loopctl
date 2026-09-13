defmodule Loopctl.Delivery.PostDeployVerification.Result do
  @moduledoc """
  One post-deploy verification of one story (issue #803, design §9).

  - `decision` — one of three:
    - `:verified` — the story's merge is running in the target deployment. The story takes
      `{deployed, verified, :forward}`
    - `:failed` — it is not, or the deploy did not succeed, or something could not be
      established that a human has to look at. The story takes
      `{deployed, escalated, :verification_failed}`
    - `:unresolved` — no verdict yet: the forge was transiently unavailable, or the deploy
      has not been created, settled, or carried this merge. NOTHING transitions and the next
      sweep asks again. Never an escalation on its own, because `escalated` is human-only and
      one network blip (or one queued build) must not park a story on Mark. It escalates only
      once the consecutive count for its KIND passes
      `PostDeployVerification.max_consecutive_unresolved/1`
  - `unresolved_kind` — `:forge_fault` or `:deploy_pending`, on an `:unresolved` result and
    `nil` otherwise. The two have different bounds and are counted separately, because one
    number for both made every repository whose deploy takes longer than ten minutes
    escalate its whole happy path
  - `merged_at` — when the loop recorded the merge, from the stage event that wrote it.
    Deployments created before this cannot carry the merge, and telling those apart from a
    deploy that shipped something else is the difference between waiting and escalating
  - `reasons` — every reason the decision is what it is, all of them rather than the first,
    so one escalation names the whole list. Empty on `:verified`
  - `merge_sha` — the merge the story recorded, read from the STAGE ROW and never from a
    caller. This is the commit that had to ship
  - `deployed_sha` — the commit the DEPLOYMENT names, when one could be read. Both shas are
    on the result and both are named in the escalation reason, because "the wrong thing is
    deployed" is unactionable without saying which two commits disagree
  - `deployment_id`, `deployment_state` — which deployment the verdict came from and what
    the forge said about it. That is the one CARRYING the merge when there is one, and the
    newest candidate otherwise — never simply the newest, which is how a later story's
    failed deploy escalated an earlier story that had already shipped
  - `repo` — the repository, resolved server-side from the story's project
  - `retry_after` — on `:unresolved`, the seconds the FORGE asked a caller to wait, when it
    said so at all. A rate limit is the dominant cause, so a sweep that ignored it would
    amplify the condition it is waiting out
  - `resolution` — what this verdict means to the person who reported the issue
    (`Loopctl.Delivery.Resolution`). It travels ON the result so a verdict and the text it
    implies can never be decided in two places: `:verified` is the ONLY thing that produces
    a `:shipped` resolution, and an unresolved sweep produces the same "say nothing"
    resolution an escalation does

  ## It is a value, never an authority

  Nothing stores a result as the fact that a story is verified. It is recomputed from the
  forge and the database on every sweep. What IS persisted is the consequence: the
  transition, written through the stage machine.
  """

  alias Loopctl.Delivery.Resolution

  @enforce_keys [:decision, :reasons, :resolution]
  defstruct [
    :decision,
    :reasons,
    :resolution,
    :unresolved_kind,
    :repo,
    :merge_sha,
    :merged_at,
    :deployed_sha,
    :deployment_id,
    :deployment_state,
    :retry_after
  ]

  @type decision :: :verified | :failed | :unresolved

  @type t :: %__MODULE__{
          decision: decision(),
          reasons: [term()],
          resolution: Resolution.t(),
          unresolved_kind: :forge_fault | :deploy_pending | nil,
          repo: String.t() | nil,
          merge_sha: String.t() | nil,
          merged_at: DateTime.t() | nil,
          deployed_sha: String.t() | nil,
          deployment_id: integer() | nil,
          deployment_state: atom() | nil,
          retry_after: pos_integer() | nil
        }
end
