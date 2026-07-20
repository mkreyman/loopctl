defmodule Loopctl.Knowledge.IngestionWriteStats do
  @moduledoc """
  Schema for the `ingestion_write_stats` table — a durable per-(tenant,
  source_type, day) rollup of KB article WRITE OUTCOMES.

  Where `Loopctl.Knowledge.IngestionAnomaly` (capture-silence) is a dead-man's-switch
  read off the `articles` table ("writes STOPPED"), this rollup captures the OTHER
  outage signature: writes ATTEMPTED but REJECTED at high rate. A rejected write
  (409 title_conflict, changeset validation error) leaves NO article row, so it is
  invisible to any row-count monitor. Instead the self-rescuing
  `[:loopctl, :knowledge, :article_write]` telemetry handler
  (`Loopctl.Telemetry.IngestionWriteStats`) increments the matching counter here on
  EVERY write outcome, and `Loopctl.Knowledge.IngestionHealth` flags a
  `:high_reject_rate` anomaly when rejects dominate a rolling window.

  ## Outcome -> column mapping

  - `:created`          -> `created_count`
  - `:deduplicated`     -> `deduplicated_count`
  - `:gated_to_draft`   -> `drafted_count`
  - `:title_conflict`   -> `title_conflict_count`
  - `:validation_error` -> `validation_error_count`
  - `:forbidden`        -> `forbidden_count`

  `:forbidden` counts UPFRONT AUTHORIZATION rejections (a 403 — wrong scope/role or a
  missing agent identity). It is tracked for observability but is DELIBERATELY EXCLUDED
  from the high_reject_rate detector's reject numerator AND denominator
  (`IngestionHealth.detect_high_reject_rate/1` selects only the five ingestion outcomes):
  a caller merely mis-using scope/identity (a 403 storm) is permission misuse, NOT an
  ingestion-pipeline outage, and must not page the operator with a `high_reject_rate`
  alert nor dilute a genuine `title_conflict`/`validation_error` reject signal.

  `source_type` is NULLABLE (an article write may omit the advisory field); the
  `(tenant_id, COALESCE(source_type, ''), day)` unique index buckets NULL distinctly
  so the per-write upsert is idempotent per bucket.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # The five INGESTION-pipeline outcome counters the high_reject_rate detector reads.
  @counter_fields [
    :created_count,
    :deduplicated_count,
    :drafted_count,
    :title_conflict_count,
    :validation_error_count
  ]

  # Upfront-authorization (403) rejections. Tracked for observability but kept OUT of
  # @counter_fields so it is excluded from the reject-rate detector (numerator AND
  # denominator) — a 403 storm is permission misuse, not an ingestion outage.
  @authz_fields [:forbidden_count]

  # All upsertable counter columns (ingestion outcomes + authz rejections).
  @all_counter_fields @counter_fields ++ @authz_fields

  # Telemetry outcome -> counter column. The single source of truth for the mapping
  # (used by the telemetry handler and the reject-rate detector).
  @outcome_columns %{
    created: :created_count,
    deduplicated: :deduplicated_count,
    gated_to_draft: :drafted_count,
    title_conflict: :title_conflict_count,
    validation_error: :validation_error_count,
    forbidden: :forbidden_count
  }

  @derive {Jason.Encoder,
           only:
             [
               :id,
               :tenant_id,
               :source_type,
               :day
             ] ++ @all_counter_fields ++ [:inserted_at, :updated_at]}

  schema "ingestion_write_stats" do
    tenant_field()

    field :source_type, :string
    field :day, :date

    field :created_count, :integer, default: 0
    field :deduplicated_count, :integer, default: 0
    field :drafted_count, :integer, default: 0
    field :title_conflict_count, :integer, default: 0
    field :validation_error_count, :integer, default: 0
    field :forbidden_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The five INGESTION-outcome counter column names read by the reject-rate detector."
  @spec counter_fields() :: [atom()]
  def counter_fields, do: @counter_fields

  @doc """
  The counter column for a telemetry `outcome`, or `nil` for an unknown outcome
  (the handler skips unknown outcomes rather than raising).
  """
  @spec column_for(atom()) :: atom() | nil
  def column_for(outcome), do: Map.get(@outcome_columns, outcome)

  @doc """
  Changeset for an upsert row. `tenant_id` is set programmatically on the struct
  (RLS rule — never cast).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(stats \\ %__MODULE__{}, attrs) do
    stats
    |> cast(attrs, [:source_type, :day | @all_counter_fields])
    |> validate_required([:day])
    |> foreign_key_constraint(:tenant_id)
  end
end
