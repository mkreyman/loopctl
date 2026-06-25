defmodule Loopctl.Repo.Migrations.CreateKnowledgeBulkDeleteTokens do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # US-27.12: frozen-set tokens for the TOCTOU-safe bulk HARD-delete path.
  #
  # The dry-run for the irreversible delete variant mints a row here whose `id`
  # IS the secret — server-minted binary_id, returned to the client and required
  # on the real run. The stored `article_ids` is the FROZEN id-set, so the real
  # delete operates on exactly the previewed rows (not whatever the selector
  # matches at execution time — that closes the TOCTOU window). Tokens are
  # single-use (`used_at`) and TTL-bounded (`expires_at`). A forged token can't
  # target another tenant's rows: the row carries `tenant_id` and is loaded by
  # (id AND tenant_id), and RLS scopes it as well.
  def change do
    create table(:knowledge_bulk_delete_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :article_ids, {:array, :binary_id}, null: false, default: []
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      # Only `inserted_at` — tokens are immutable except for the single-use
      # `used_at` stamp, so no `updated_at`.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:knowledge_bulk_delete_tokens, [:tenant_id])

    enable_rls(:knowledge_bulk_delete_tokens)
  end
end
