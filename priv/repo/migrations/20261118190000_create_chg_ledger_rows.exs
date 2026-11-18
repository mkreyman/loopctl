defmodule Loopctl.Repo.Migrations.CreateChgLedgerRows do
  @moduledoc """
  US-50.1: `chg_ledger_rows`, the fleet's chg shadow-ledger rows, delivered in batches by each
  machine's outbox sender (`POST /api/v1/chg_ledger/:source_id`).

  One row per delivered ledger row. `row_hash` is the sha256 of the row's canonical JSON, and
  the unique index on `(tenant_id, source_id, host, row_hash)` is the idempotency key: a
  redelivered batch inserts nothing. `raw` keeps the row as delivered, so a kind loopctl does
  not model yet is still answerable later.

  `repo` is the canonical key (downcased), held by a CHECK as on `change_events`.

  A new table and nothing else, so the code running before this release keeps working during
  Fly's rolling deploy.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:chg_ledger_rows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repo, :string, null: false
      add :host, :string, null: false
      add :kind, :string, null: false
      add :sha, :string
      add :at, :utc_datetime_usec, null: false
      add :verdict, :string
      add :ms, :bigint
      add :raw, :map, null: false
      add :row_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:chg_ledger_rows, [:tenant_id, :source_id, :host, :row_hash])

    # The dashboard's and the summary's read (US-50.5, US-50.6): one repository's rows of one
    # kind over a window.
    create index(:chg_ledger_rows, [:tenant_id, :repo, :kind, :at])

    # The prune's read: a tenant's rows past the retention window, oldest first.
    create index(:chg_ledger_rows, [:tenant_id, :at])

    create constraint(:chg_ledger_rows, :chg_ledger_rows_repo_canonical,
             check: "repo = lower(repo)"
           )

    create constraint(:chg_ledger_rows, :chg_ledger_rows_verdict_known,
             check: "verdict IS NULL OR verdict IN ('pass', 'fail', 'error', 'skipped')"
           )

    create constraint(:chg_ledger_rows, :chg_ledger_rows_ms_non_negative,
             check: "ms IS NULL OR ms >= 0"
           )

    enable_rls(:chg_ledger_rows)
  end

  def down do
    drop table(:chg_ledger_rows)
  end
end
