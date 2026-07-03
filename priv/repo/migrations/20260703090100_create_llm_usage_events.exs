defmodule Loopctl.Repo.Migrations.CreateLlmUsageEvents do
  @moduledoc """
  Epic 28 residual (#179): per-tenant LLM token-usage tracking.

  One row per successful tenant LLM operation (extraction/classification/merge),
  capturing the model used and the Anthropic-reported input/output token counts.
  This is a RECORD-ONLY ledger — there is NO budget enforcement; it backs the
  per-tenant usage-summary API (`GET /api/v1/knowledge/llm-usage`).

  RLS-enforced like every other tenant table. Composite indexes on
  (tenant_id, occurred_at) and (tenant_id, operation) back the summary
  aggregation + date-range window.
  """
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:llm_usage_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # extraction | classification | merge (Ecto.Enum in the schema).
      add :operation, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0

      # Optional provenance for the summary breakdown.
      add :source_type, :string, null: true
      add :article_id, :binary_id, null: true

      add :occurred_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:llm_usage_events, [:tenant_id, :occurred_at])
    create index(:llm_usage_events, [:tenant_id, :operation])

    enable_rls(:llm_usage_events)
  end
end
