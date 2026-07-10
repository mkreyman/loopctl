defmodule Loopctl.Memory.PromotionEvalSnapshot do
  @moduledoc """
  A daily promotion-compile-quality snapshot (Epic 29 / US-29.5).

  `precision`/`recall` measure how well `Loopctl.Memory.Promoter` turns a COMMITTED
  labeled synthetic dataset's sessions into durable-fact candidates, scored against
  ground-truth labels (NOT a live LLM judge). It is calibration/observability only —
  it never gates promotion and never re-judges production memories. Tracked over time
  so a compile-quality regression (e.g. a poisoning/injection regression per
  US-29.1 AC-29.1.5) is visible.

  `tenant_id` is set programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "promotion_eval_snapshots" do
    tenant_field()

    field :day, :date
    field :dataset_version, :string
    field :session_count, :integer, default: 0
    field :true_positives, :integer, default: 0
    field :false_positives, :integer, default: 0
    field :false_negatives, :integer, default: 0
    field :precision, :float, default: 0.0
    field :recall, :float, default: 0.0
    field :computed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :day,
    :dataset_version,
    :session_count,
    :true_positives,
    :false_positives,
    :false_negatives,
    :precision,
    :recall,
    :computed_at
  ]

  @doc "Changeset for a snapshot. `tenant_id` is set on the struct, not cast."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(snapshot \\ %__MODULE__{}, attrs) do
    snapshot
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :day,
      :dataset_version,
      :session_count,
      :true_positives,
      :false_positives,
      :false_negatives,
      :precision,
      :recall,
      :computed_at
    ])
    |> unique_constraint([:tenant_id, :dataset_version, :day],
      name: :promotion_eval_snapshots_tenant_version_day_index
    )
  end
end
