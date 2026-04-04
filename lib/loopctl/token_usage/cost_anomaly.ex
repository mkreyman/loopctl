defmodule Loopctl.TokenUsage.CostAnomaly do
  @moduledoc """
  Schema for the `cost_anomalies` table.

  Tracks stories whose cost deviates significantly from the epic average.
  Created by the `CostAnomalyWorker` after each daily rollup.

  ## Anomaly Types

  - `high_cost` -- story cost exceeds 3x the epic average
  - `suspiciously_low` -- story cost is below 0.1x the epic average
  - `budget_exceeded` -- story cost exceeds the configured budget

  ## Fields

  - `story_id` -- FK to the flagged story
  - `anomaly_type` -- one of the types above
  - `story_cost_millicents` -- the story's actual cost
  - `reference_avg_millicents` -- the epic average used for comparison
  - `deviation_factor` -- how many times the story cost deviates from average
  - `resolved` -- whether the anomaly has been acknowledged/resolved
  - `metadata` -- extensible JSONB map
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @anomaly_types [:high_cost, :suspiciously_low, :budget_exceeded]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :anomaly_type,
             :story_cost_millicents,
             :reference_avg_millicents,
             :deviation_factor,
             :resolved,
             :archived,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "cost_anomalies" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story

    field :anomaly_type, Ecto.Enum, values: @anomaly_types
    field :story_cost_millicents, :integer
    field :reference_avg_millicents, :integer
    field :deviation_factor, :decimal
    field :resolved, :boolean, default: false
    # AC-21.14.5: Archived anomalies are excluded from default list
    field :archived, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Changeset for creating a cost anomaly.

  The `tenant_id` and `story_id` are set programmatically and must not be in cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(anomaly \\ %__MODULE__{}, attrs) do
    anomaly
    |> cast(attrs, [
      :anomaly_type,
      :story_cost_millicents,
      :reference_avg_millicents,
      :deviation_factor,
      :resolved,
      :metadata
    ])
    |> validate_required([
      :anomaly_type,
      :story_cost_millicents,
      :reference_avg_millicents,
      :deviation_factor
    ])
    |> validate_inclusion(:anomaly_type, @anomaly_types)
    |> validate_number(:story_cost_millicents, greater_than_or_equal_to: 0)
    |> validate_number(:reference_avg_millicents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:story_id)
  end

  @doc """
  Changeset for resolving an anomaly.
  """
  @spec resolve_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def resolve_changeset(anomaly) do
    change(anomaly, resolved: true)
  end
end
