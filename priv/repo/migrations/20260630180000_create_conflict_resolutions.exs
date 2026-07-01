defmodule Loopctl.Repo.Migrations.CreateConflictResolutions do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Route-the-findings #4, step 1: a retrieving agent (which has live context) records
  # its VERDICT on a potential-conflict pair here — the KB/executor never re-judges.
  # A nightly executor applies dismiss/supersede from these rows. Kept separate from
  # article_links because links are immutable by design; this row is mutable
  # (last-write-wins on re-annotation; executor stamps executed_at).
  def change do
    create table(:conflict_resolutions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # Canonical (sorted) article pair — one resolution per unordered pair.
      add :source_article_id, references(:articles, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_article_id, references(:articles, type: :binary_id, on_delete: :delete_all),
        null: false

      add :classification, :string
      add :disposition, :string, null: false
      # The winning article for :supersede / :merge (loser is the other pair member).
      add :authoritative_article_id,
          references(:articles, type: :binary_id, on_delete: :nilify_all)

      add :evidence, :text
      add :confidence, :string, null: false, default: "medium"
      add :annotated_by, :string
      add :annotated_at, :utc_datetime_usec, null: false
      add :executed_at, :utc_datetime_usec
      add :execution_result, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # One resolution per (tenant, canonical pair). Re-annotation upserts (last-write-wins).
    create unique_index(
             :conflict_resolutions,
             [:tenant_id, :source_article_id, :target_article_id],
             name: :conflict_resolutions_tenant_pair_index
           )

    create index(:conflict_resolutions, [:tenant_id])
    # Executor scan: unexecuted rows.
    create index(:conflict_resolutions, [:tenant_id, :executed_at])

    enable_rls(:conflict_resolutions)
  end
end
