defmodule Loopctl.Repo.Migrations.SeedDispatchLineageArticle do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO articles (id, tenant_id, scope, slug, title, body, category, status, metadata, tags, inserted_at, updated_at)
    VALUES (
      gen_random_uuid(),
      NULL,
      'system',
      'dispatch-lineage',
      'Dispatch Lineage — Ephemeral Keys and Sub-Agent Identity',
      '# Dispatch Lineage

    _Full content for this article will be authored in US-26.3.3 (Phase 3)._

    Dispatch lineage replaces the shared long-lived LOOPCTL_AGENT_KEY pattern
    with per-task ephemeral keys that carry their parent lineage. Each dispatch
    records the full path from root to self, enabling the chain of custody to
    detect sock-puppet sub-agents that share an ancestor with the implementer.

    See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.
    See [Agent Bootstrap](/wiki/agent-bootstrap) for getting started.',
      'reference',
      'published',
      '{"authored_by": "epic_26_phase_2"}',
      '{}',
      NOW(),
      NOW()
    )
    ON CONFLICT (slug) WHERE scope = 'system'
    DO UPDATE SET
      title = EXCLUDED.title,
      body = EXCLUDED.body,
      updated_at = NOW()
    """)
  end

  def down do
    execute("DELETE FROM articles WHERE scope = 'system' AND slug = 'dispatch-lineage'")
  end
end
