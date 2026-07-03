defmodule Loopctl.Repo.Migrations.CreateTenantLlmSettings do
  @moduledoc """
  Epic 28 residual (#179): per-tenant BYO Anthropic LLM configuration.

  One row per tenant holding the tenant's OWN Anthropic API key (encrypted at
  rest via Cloak `Loopctl.Vault.Binary` — the column is opaque `:binary`
  ciphertext) plus the granular per-operation model choices
  (extraction/classification/merge). loopctl fronts no LLM cost: the tenant's key
  bills the tenant directly.

  RLS-enforced like every other tenant table (`ENABLE ROW LEVEL SECURITY`, not
  FORCE — the production owner role has no BYPASSRLS) with a `tenant_isolation`
  policy `USING (tenant_id = current_tenant_id())`. The context layer additionally
  filters by tenant_id explicitly (it runs from Oban workers on AdminRepo too),
  matching the `Loopctl.Webhooks` encrypted-secret precedent.
  """
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:tenant_llm_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # Cloak-encrypted Anthropic API key (AES-256-GCM). Opaque ciphertext at rest.
      add :api_key, :binary, null: true

      # Granular per-operation model ids. NULL means "use the server default for
      # that operation" (see Loopctl.Llm.resolve/2). Free-form — validated as a
      # plausible non-empty id, NOT restricted to an allow-list.
      add :extraction_model, :string, null: true
      add :classification_model, :string, null: true
      add :merge_model, :string, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # Exactly one settings row per tenant.
    create unique_index(:tenant_llm_settings, [:tenant_id])

    enable_rls(:tenant_llm_settings)
  end
end
