defmodule Loopctl.Repo.Migrations.AddEmbeddingToTenantLlmSettings do
  @moduledoc """
  Extend per-tenant BYO LLM config (#294) to EMBEDDINGS.

  Adds two columns to the existing `tenant_llm_settings` table (no new table — the
  RLS policy already on `tenant_llm_settings` covers them):

    * `embedding_api_key` — the tenant's OWN OpenAI-compatible embedding key,
      encrypted at rest via Cloak `Loopctl.Vault.Binary` (opaque `:binary`
      ciphertext), SEPARATE from the Anthropic `api_key`.
    * `embedding_model`   — free-form embedding model id (NULL → server default
      `text-embedding-3-small`; see `Loopctl.Llm.resolve/2`).

  Mandatory BYO: a tenant with no `embedding_api_key` gets NO embeddings — their
  articles are created successfully but are not vector-searchable until they
  configure a key. loopctl fronts no embedding cost: the tenant's key bills the
  tenant directly.
  """
  use Ecto.Migration

  def change do
    alter table(:tenant_llm_settings) do
      # Cloak-encrypted OpenAI embedding key (AES-256-GCM). Opaque ciphertext at rest.
      add :embedding_api_key, :binary, null: true

      # Free-form embedding model id. NULL means "use the server default"
      # (see Loopctl.Llm.resolve/2). Validated as a plausible non-empty id,
      # NOT restricted to an allow-list.
      add :embedding_model, :string, null: true
    end
  end
end
