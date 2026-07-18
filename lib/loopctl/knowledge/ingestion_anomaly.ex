defmodule Loopctl.Knowledge.IngestionAnomaly do
  @moduledoc """
  Schema for the `ingestion_anomalies` table.

  A capture-silence anomaly is a **dead-man's-switch** for knowledge ingestion:
  it records that a tenant which HISTORICALLY produced captured articles of a
  given `source_type` (e.g. `"session_log"`) has gone silent — no new article of
  that source_type has been written for longer than the staleness threshold.

  This is the sibling detector-class to `Loopctl.TokenUsage.CostAnomaly`. Where
  CostAnomaly (and ScaleAlerts) detect the *presence of errors*, this detects the
  *absence of expected success* — the failure mode where session-knowledge capture
  silently stopped (articles rejected/dropped) and nothing noticed the missing writes.
  Created by `Loopctl.Workers.IngestionHealthWorker`.

  ## Anomaly Types

  - `capture_silence` -- an established source_type produced no new article for
    longer than the configured staleness threshold.

  ## Fields

  - `source_type` -- the article `source_type` whose capture stream went silent
  - `anomaly_type` -- one of the types above
  - `last_event_at` -- `max(inserted_at)` of that source_type's articles (nil if none)
  - `hours_stale` -- whole hours between `last_event_at` and detection time
  - `sample_count` -- total articles of that source_type (the "established" evidence)
  - `resolved` -- whether the anomaly has been acknowledged/resolved
  - `archived` -- archived anomalies are excluded from the default list
  - `metadata` -- extensible JSONB map
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # Extensible list — a future detector (e.g. `:capture_drop_rate`) can be added
  # here alongside the CHECK constraint in the migration.
  @anomaly_types [:capture_silence]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :source_type,
             :anomaly_type,
             :last_event_at,
             :hours_stale,
             :sample_count,
             :resolved,
             :archived,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "ingestion_anomalies" do
    tenant_field()

    field :source_type, :string
    field :anomaly_type, Ecto.Enum, values: @anomaly_types
    field :last_event_at, :utc_datetime_usec
    field :hours_stale, :integer
    field :sample_count, :integer
    field :resolved, :boolean, default: false
    field :archived, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc "The known anomaly types."
  @spec anomaly_types() :: [atom()]
  def anomaly_types, do: @anomaly_types

  @doc """
  Changeset for creating a capture-silence anomaly.

  The `tenant_id` is set programmatically and must not be in cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(anomaly \\ %__MODULE__{}, attrs) do
    anomaly
    |> cast(attrs, [
      :source_type,
      :anomaly_type,
      :last_event_at,
      :hours_stale,
      :sample_count,
      :resolved,
      :metadata
    ])
    |> validate_required([:source_type, :anomaly_type, :hours_stale, :sample_count])
    |> validate_inclusion(:anomaly_type, @anomaly_types)
    |> validate_number(:hours_stale, greater_than_or_equal_to: 0)
    |> validate_number(:sample_count, greater_than_or_equal_to: 0)
    |> validate_metadata_size()
    |> foreign_key_constraint(:tenant_id)
  end

  @doc """
  Changeset for resolving an anomaly.
  """
  @spec resolve_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def resolve_changeset(anomaly) do
    change(anomaly, resolved: true)
  end

  @metadata_max_bytes 65_536

  defp validate_metadata_size(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if byte_size(Jason.encode!(value)) > @metadata_max_bytes,
        do: [metadata: "must be smaller than 64KB"],
        else: []
    end)
  end
end
