defmodule Loopctl.Delivery.StageEvent do
  @moduledoc """
  Schema for the `story_stage_events` table — the non-chained history of a story's stage row
  (issue #803, design §11). Append-only by convention: `Loopctl.Delivery.Stages` inserts and
  never updates.

  - `opened` — the row was created (at `detected`).
  - `transitioned` — `from_stage -> to_stage` over `edge`; `data` carries the reason, if any.
  - `rebound` — a claim release moved the row to the story's new `claim_epoch` without
    changing its stage (`Loopctl.Delivery.Stages.follow_release/5`).
  - `effect_recorded` — a side-effect identity was set for the first time; `data` carries
    its name and value, so an identity a later edge clears is still on record here.
  - `merge_gate_unevaluated` — the merge precondition ran and produced NO verdict because
    the forge was transiently unavailable (#803); `data` carries the head and the
    consecutive count. Nothing transitions on one of these, so without the event a story
    going quiet would leave no trace at all.
  - `post_deploy_unresolved` — the same, for post-deploy verification (#803 §9): a sweep
    that reached no verdict because the forge was unavailable or the deploy had not
    settled. `data` carries the merge sha, the KIND of waiting (`forge_fault` or
    `deploy_pending`, which have different bounds) and the consecutive count.
  - `merge_instructed` — control pushed (or tried to push) a merge instruction for the
    story's head to the runner holding its claim (US-48.17); `data` carries the instruction
    record as `story_stages.merge_instruction` now holds it, outcome included.
  - `runner_absence` — the story's runner was found with no live socket while the story
    waited at `ci`, or was found live again after that (US-48.17); `data` carries the
    absence record, or `"cleared"` with the one that ended.

  **This list is the `story_stage_events_event` CHECK's allow-list.** Adding an event name
  means a migration that rewrites the constraint AND a line here; the two drifting is how a
  reader learns the vocabulary wrong.

  Custody-critical transitions are ALSO on the audit chain; this table is the complete
  record and the chain the tamper-evident one.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "story_stage_events" do
    tenant_field()
    field :story_stage_id, :binary_id
    field :story_id, :binary_id
    field :event, :string
    field :from_stage, :string
    field :to_stage, :string
    field :edge, :string
    field :claim_epoch, :integer
    field :lock_version, :integer
    field :actor_label, :string
    field :data, :map, default: %{}

    timestamps(updated_at: false)
  end
end
