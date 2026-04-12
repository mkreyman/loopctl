defmodule Loopctl.Repo.Migrations.SeedErrorCodeArticles do
  use Ecto.Migration

  @error_codes [
    {"self-verify-blocked", "Self-Verify Blocked"},
    {"self-report-blocked", "Self-Report Blocked"},
    {"self-review-blocked", "Self-Review Blocked"},
    {"missing-capability", "Missing Capability Token"},
    {"wrong-lineage", "Wrong Dispatch Lineage"},
    {"expired-capability", "Expired Capability Token"},
    {"consumed-nonce", "Consumed Token Nonce"},
    {"verifier-needed", "Verifier Needed"},
    {"missing-dispatch", "Missing Dispatch"},
    {"one-agent-one-role", "One Agent One Role"},
    {"api-key-role-immutable", "API Key Role Immutable"}
  ]

  def up do
    for {slug, title} <- @error_codes do
      execute("""
      INSERT INTO articles (id, tenant_id, scope, slug, title, body, category, status, metadata, tags, inserted_at, updated_at)
      VALUES (
        gen_random_uuid(),
        NULL,
        'system',
        '#{slug}',
        '#{title}',
        '# #{title}

      _Full content for this article will be authored in US-26.3.3 (Phase 3)._

      This error occurs when a chain-of-custody invariant is violated.
      See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.',
        'reference',
        'published',
        '{"authored_by": "epic_26_phase_3"}',
        '{}',
        NOW(),
        NOW()
      )
      ON CONFLICT (slug) WHERE scope = 'system'
      DO UPDATE SET title = EXCLUDED.title, updated_at = NOW()
      """)
    end
  end

  def down do
    for {slug, _title} <- @error_codes do
      execute("DELETE FROM articles WHERE scope = 'system' AND slug = '#{slug}'")
    end
  end
end
