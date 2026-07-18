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

  `source_type` is NULLABLE (an article write may omit the advisory field); the
  `(tenant_id, COALESCE(source_type, ''), day)` unique index buckets NULL distinctly
  so the per-write upsert is idempotent per bucket.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @counter_fields [
    :created_count,
    :deduplicated_count,
    :drafted_count,
    :title_conflict_count,
    :validation_error_count
  ]

  # Telemetry outcome -> counter column. The single source of truth for the mapping
  # (used by the telemetry handler and the reject-rate detector).
  @outcome_columns %{
    created: :created_count,
    deduplicated: :deduplicated_count,
    gated_to_draft: :drafted_count,
    title_conflict: :title_conflict_count,
    validation_error: :validation_error_count
  }

  @derive {Jason.Encoder,
           only:
             [
               :id,
               :tenant_id,
               :source_type,
               :day
             ] ++ @counter_fields ++ [:inserted_at, :updated_at]}

  schema "ingestion_write_stats" do
    tenant_field()

    field :source_type, :string
    field :day, :date

    field :created_count, :integer, default: 0
    field :deduplicated_count, :integer, default: 0
    field :drafted_count, :integer, default: 0
    field :title_conflict_count, :integer, default: 0
    field :validation_error_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The five per-outcome counter column names."
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
    |> cast(attrs, [:source_type, :day | @counter_fields])
    |> validate_required([:day])
    |> foreign_key_constraint(:tenant_id)
  end
end
