defmodule Loopctl.Repo.Migrations.CreateKbCurationEvents do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # A concise, human-readable log of KB CURATION adjustments (novelty-gate decisions,
  # conflict supersede/merge/dismiss, ...) — the skimmable "what did the KB change" feed,
  # distinct from the verbose immutable audit_log. Written only when the
  # `:kb_curation_log` flag is on (rollout observability; off = no rows). Analyzed via
  # GET /knowledge/curation-log, filterable by kind/date.
  def change do
    create table(:kb_curation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :kind, :string, null: false
      add :summary, :text, null: false
      add :refs, {:array, :binary_id}, null: false, default: []
      add :actor, :string
      add :confidence, :string
      add :metadata, :map, null: false, default: %{}
      add :at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:kb_curation_events, [:tenant_id, :at])
    create index(:kb_curation_events, [:tenant_id, :kind, :at])

    enable_rls(:kb_curation_events)
  end
end
