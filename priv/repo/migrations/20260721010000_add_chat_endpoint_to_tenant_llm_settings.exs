defmodule Loopctl.Repo.Migrations.AddChatEndpointToTenantLlmSettings do
  use Ecto.Migration

  # US-41.3: pluggable chat provider for the extraction / classification / merge /
  # content-extraction / memory-promotion surface.
  #
  # All three columns are NULLABLE and NULL means "unchanged Anthropic default"
  # (AC-41.3.7): a tenant that configures nothing keeps the hardcoded
  # `https://api.anthropic.com/v1` endpoint, the `api_key` credential and byte
  # identical behaviour.
  #
  #   * chat_provider  — "anthropic" | "openai_compatible" (NULL => anthropic)
  #   * chat_base_url  — the OpenAI-compatible base url (no trailing /chat/completions)
  #   * chat_api_key   — Cloak-encrypted credential for THAT endpoint. It is a
  #     SEPARATE column from `api_key` on purpose: the Anthropic key must never be
  #     shipped to a tenant-supplied host (AC-41.3.3's credential rule).
  #
  # `llm_usage_events.provider` makes the usage ledger provider-attributed, so a
  # local endpoint's rows are distinguishable from Anthropic's instead of silently
  # blending (AC-41.3.6).
  #
  # The column default backfills every PRE-EXISTING row as "anthropic", which is
  # right for the three chat operations but WRONG for `operation = 'embedding'`:
  # embedding spend was never Anthropic's, and new embedding rows are written with
  # provider "embedding" (`Loopctl.Knowledge.EmbeddingClient`). Left uncorrected,
  # identical embedding work would split across two provider labels at an arbitrary
  # deploy boundary and historical OpenAI embedding spend would be reported under
  # Anthropic — the opposite of the attributed ledger AC-41.3.6 asks for. So the
  # backfill is corrected in the SAME migration, before any read can see it.

  def change do
    alter table(:tenant_llm_settings) do
      add :chat_provider, :string
      add :chat_base_url, :string
      add :chat_api_key, :binary
    end

    alter table(:llm_usage_events) do
      add :provider, :string, null: false, default: "anthropic"
    end

    # Re-attribute the historical embedding rows. Reversible-safe: `up`-only work
    # inside `change/0` is fine here because the DOWN path drops the column
    # entirely, so the corrected values are discarded with it.
    execute(
      "UPDATE llm_usage_events SET provider = 'embedding' WHERE operation = 'embedding'",
      "SELECT 1"
    )
  end
end
