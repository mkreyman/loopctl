defmodule Loopctl.Repo.Migrations.SeedVerificationWitnessArticles do
  use Ecto.Migration

  @articles [
    %{
      slug: "verification-runs",
      title: "Verification Runs — Independent Re-Execution",
      body: """
      # Verification Runs

      Verification runs provide SWE-bench-style independent re-execution
      of a story's acceptance criteria. Instead of trusting the implementer's
      self-report, loopctl re-checks each AC against the committed code.

      ## How it works

      1. A verification run is enqueued when verify_story is called
      2. The runner fetches the commit SHA and computes a content hash
      3. For each AC, the runner checks the verification_criterion:
         - **test**: runs the named test and checks it passes
         - **code**: greps for the pattern in the file
         - **route**: checks the router for the endpoint
         - **migration**: checks the migration for the column
         - **manual**: flags for operator review
      4. Results are stored per-AC in the verification_run record

      See [Acceptance Criteria Bindings](/wiki/acceptance-criteria-bindings)
      for criterion format details.
      """
    },
    %{
      slug: "witness-protocol",
      title: "Witness Protocol — Cross-Agent Tamper Detection",
      body: """
      # Witness Protocol

      The witness protocol provides cross-agent tamper detection via
      PubSub-broadcast Signed Tree Heads (STHs).

      ## How agents participate

      1. Each agent subscribes to the tenant's audit chain PubSub topic
      2. STH updates are broadcast every 60 seconds
      3. Agents cache the latest STH locally
      4. On every API request, agents include the `X-Loopctl-Last-Known-STH`
         header with their cached position and signature prefix

      ## Divergence detection

      If an agent's cached STH doesn't match the server's record for that
      position, a divergence is detected. This means someone rewrote the
      chain — which requires compromising every connected agent's memory
      simultaneously.

      ## Custody halt

      On divergence, the tenant's custody operations are halted until an
      operator clears the halt via break-glass with WebAuthn.

      See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.
      See [Break Glass](/wiki/break-glass) for emergency procedures.
      """
    }
  ]

  def up do
    for article <- @articles do
      execute("""
      INSERT INTO articles (id, tenant_id, scope, slug, title, body, category, status, metadata, tags, inserted_at, updated_at)
      VALUES (
        gen_random_uuid(),
        NULL,
        'system',
        '#{article.slug}',
        '#{escape_sql(article.title)}',
        '#{escape_sql(article.body)}',
        'reference',
        'published',
        '{"authored_by": "epic_26_phase_4_5"}',
        '{}',
        NOW(),
        NOW()
      )
      ON CONFLICT (slug) WHERE scope = 'system'
      DO UPDATE SET title = EXCLUDED.title, body = EXCLUDED.body, updated_at = NOW()
      """)
    end
  end

  def down do
    for article <- @articles do
      execute("DELETE FROM articles WHERE scope = 'system' AND slug = '#{article.slug}'")
    end
  end

  defp escape_sql(text), do: String.replace(text, "'", "''")
end
