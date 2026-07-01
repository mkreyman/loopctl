defmodule Loopctl.Knowledge.RetrievalMetricSnapshot do
  @moduledoc """
  A daily retrieval-precision snapshot (agents' KB #3). `precision` is the share of a
  day's search results the agent then opened (search → get/context within
  `window_seconds`) — a mechanical proxy for retrieval quality, tracked over time.

  `tenant_id` is set programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "retrieval_metric_snapshots" do
    tenant_field()

    field :day, :date
    field :window_seconds, :integer
    field :searched, :integer, default: 0
    field :followed_through, :integer, default: 0
    field :precision, :float, default: 0.0
    field :computed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [:day, :window_seconds, :searched, :followed_through, :precision, :computed_at]

  @doc "Changeset for a snapshot. `tenant_id` is set on the struct, not cast."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(snapshot \\ %__MODULE__{}, attrs) do
    snapshot
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :day,
      :window_seconds,
      :searched,
      :followed_through,
      :precision,
      :computed_at
    ])
    |> unique_constraint([:tenant_id, :day, :window_seconds],
      name: :retrieval_metric_snapshots_tenant_day_window_index
    )
  end
end
