defmodule Loopctl.Repo.Migrations.AddSessionDiscriminatorToChannelClaims do
  use Ecto.Migration

  # Issue #779: a claim row records WHICH AGENT holds it and nothing finer. Every
  # session in a fleet typically authenticates as one `agent_id`, so two sessions on
  # two machines are indistinguishable to the server — a peer's live claim reads back
  # as the caller's own, and `release` deletes it.
  #
  # These two columns carry the per-session / per-host discriminator the MCP proxy
  # already auto-fills on `channel_post` and `channel_lock` (`session_id`, `host`).
  # They are CLIENT-SUPPLIED, ADVISORY and SPOOFABLE — the same class as
  # `channel_posts.to_host`/`to_capability`. They are read to REPORT ownership and to
  # refuse an ACCIDENTAL cross-session `done`/`release` (overridable with `force`);
  # they are NEVER an authorization boundary. Tenant + project membership +
  # `claimant_agent_id` remain the enforced ones.
  #
  # Nullable with no backfill: every claim written before this migration, and every
  # claim from a client that sends no session (curl, an older MCP server), carries
  # NULL and is treated as UNDISCRIMINABLE — the pre-#779 agent-scoped behaviour.
  #
  # No index: neither column is ever a query predicate. They are read off a row the
  # `(tenant_id, project_id, claimant_agent_id, ref)` owner fetch already found, and
  # projected by the claims read. RLS is already ENABLED on `channel_claims`
  # (`create_channel_claims`); adding a column inherits it, so nothing to re-enable.
  def change do
    alter table(:channel_claims) do
      add :claimed_by_session, :text, null: true
      add :claimed_by_host, :text, null: true
    end
  end
end
