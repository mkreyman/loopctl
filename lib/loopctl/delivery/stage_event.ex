defmodule Loopctl.Delivery.StageEvent do
  @moduledoc """
  Schema for the `story_stage_events` table: the work item's event log (issue #803, design
  §11; US-52.16). Append-only by convention: `Loopctl.Delivery.Stages` inserts and never
  updates. Every event names the holder that acted (`actor_holder_id`, nil when the system
  acted) and a `reason` a person can read (1..2000 characters, never blank).

  Stage events (the row's own history; `story_stage_id`, `to_stage` and `lock_version` set,
  held by the `story_stage_events_stage_fields` CHECK):

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

  Item events (any story, with or without a stage row; `Stages.record_item_event/4`):

  - `claimed` — a claim was taken; `actor_holder_id` is the claiming holder.
  - `released` — a claim was given back, force-unclaimed or reclaimed; the reason says which.
  - `note_written` — a holder wrote a note on the item (US-52.17).

  **This list is the `story_stage_events_event` CHECK's allow-list.** Adding an event name
  means a migration that rewrites the constraint AND a line here; the two drifting is how a
  reader learns the vocabulary wrong.

  Custody-critical transitions are ALSO on the audit chain; this table is the complete
  record and the chain the tamper-evident one.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @max_reason_length 2_000

  @stage_events ~w(opened transitioned effect_recorded rebound merge_gate_unevaluated
                   post_deploy_unresolved merge_instructed runner_absence)
  @item_events ~w(claimed released note_written)

  # The fixed sentence each event carries when its writer gives no reason of its own.
  # `transitioned` takes its edge's sentence instead (`StageMachine.edge_reason/1`).
  @reasons %{
    "opened" => "the stage row was opened",
    "transitioned" => "the stage moved",
    "effect_recorded" => "a side effect was recorded",
    "rebound" => "the stage row followed the story to its new claim epoch",
    "merge_gate_unevaluated" => "the merge gate reached no verdict",
    "post_deploy_unresolved" => "post-deploy verification reached no verdict",
    "merge_instructed" => "a merge was instructed",
    "runner_absence" => "the runner's presence changed",
    "claimed" => "claimed",
    "released" => "released",
    "note_written" => "a note was written"
  }

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
    field :actor_holder_id, :binary_id
    field :reason, :string
    field :idempotency_key, :string
    field :data, :map, default: %{}

    timestamps(updated_at: false)
  end

  @doc "The events that belong to a stage row."
  @spec stage_events() :: [String.t()]
  def stage_events, do: @stage_events

  @doc "The events any story may carry, with or without a stage row."
  @spec item_events() :: [String.t()]
  def item_events, do: @item_events

  @doc "Each event's fixed sentence, for a writer that gives no reason of its own."
  @spec reasons() :: %{String.t() => String.t()}
  def reasons, do: @reasons

  @doc "The longest reason the column holds (`story_stage_events_reason_length`)."
  @spec max_reason_length() :: pos_integer()
  def max_reason_length, do: @max_reason_length
end
