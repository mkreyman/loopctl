defmodule Loopctl.Embeddings.RetirementObservation do
  @moduledoc """
  Schema for `embedding_retirement_observations` — one row per UTC day recording
  what the US-41.1 legacy embedding columns looked like that day (GH #551).

  Global, like `Loopctl.SystemConfig.Setting`: there is no `tenant_id`, because the
  fact recorded is a property of the deployment's schema and index usage. All access
  goes through `Loopctl.AdminRepo` (BYPASSRLS).

  See `Loopctl.Embeddings.LegacyRetirement` for what the fields mean and how a run of
  these rows becomes a retirement verdict.
  """

  use Loopctl.Schema, tenant_scoped: false

  @type t :: %__MODULE__{}

  schema "embedding_retirement_observations" do
    field :observed_on, :date
    field :observed_at, :utc_datetime_usec
    field :side_table_reads, :integer
    field :legacy_columns_present, {:array, :string}, default: []
    field :legacy_index_scans, :map, default: %{}
    field :stats_reset_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for a daily observation. Every field except `stats_reset_at` is
  required: a row that cannot state the flag value, the surviving columns and the
  scan counters is not evidence of anything, and admitting it would let a partial
  reading count toward a clear streak.

  `stats_reset_at` is nullable because `pg_stat_database.stats_reset` is genuinely
  NULL on a database whose statistics have never been reset.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :observed_on,
      :observed_at,
      :side_table_reads,
      :legacy_columns_present,
      :legacy_index_scans,
      :stats_reset_at
    ])
    |> validate_required([
      :observed_on,
      :observed_at,
      :side_table_reads,
      :legacy_columns_present,
      :legacy_index_scans
    ])
    |> unique_constraint(:observed_on)
  end
end
