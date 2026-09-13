defmodule Loopctl.Delivery.StageEvent do
  @moduledoc """
  Schema for the `story_stage_events` table — the non-chained history of a story's stage row
  (issue #803, design §11). Append-only by convention: `Loopctl.Delivery.Stages` inserts and
  never updates.

  - `opened` — the row was created (at `detected`).
  - `transitioned` — `from_stage -> to_stage` over `edge`; `data` carries the reason, if any.
  - `effect_recorded` — a side-effect identity was set for the first time; `data` carries
    its name and value, so an identity a later edge clears is still on record here.

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
