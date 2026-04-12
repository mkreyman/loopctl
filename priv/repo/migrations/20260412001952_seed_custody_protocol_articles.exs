defmodule Loopctl.Repo.Migrations.SeedCustodyProtocolArticles do
  use Ecto.Migration

  @articles [
    %{
      slug: "capability-tokens",
      title: "Capability Tokens — Signed Authorization for Custody Operations",
      body: """
      # Capability Tokens

      Capability tokens are signed, scoped, non-replayable authorization tokens
      that gate custody-critical operations in loopctl. Without a valid cap,
      the forbidden operation is structurally unreachable.

      ## Token types

      | Type | Minted at | Consumed by | Gates |
      |------|-----------|-------------|-------|
      | `start_cap` | claim_story | start_story | Starting implementation |
      | `report_cap` | start_story | report_story | Reporting work as done |
      | `review_complete_cap` | request_review | review_complete | Recording review |
      | `verify_cap` | request_review | verify_story | Verifying work |

      ## Token structure

      Each token contains:
      - `typ` — the operation type
      - `story_id` — the story this cap authorizes
      - `issued_to_lineage` — exact dispatch lineage path of the recipient
      - `nonce` — 32 random bytes (replay protection)
      - `signature` — ed25519 signature by the tenant's audit key
      - `expires_at` — TTL (default 1 hour)

      ## Presenting a cap

      Include the `cap_id` in your request body. The server verifies:
      1. Signature matches the tenant's public key
      2. Type matches the endpoint
      3. Story matches the URL parameter
      4. Lineage exactly matches the caller's current lineage
      5. Not expired
      6. Not already consumed (replay protection)

      ## Why caps matter

      Without caps, an implementer could forge a verify request. With caps,
      the verify_cap is never minted to the implementer's lineage — they
      literally cannot construct a valid verify request.

      See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.
      See [Dispatch Lineage](/wiki/dispatch-lineage) for how lineages work.
      """
    },
    %{
      slug: "dispatch-lineage",
      title: "Dispatch Lineage — Ephemeral Keys and Sub-Agent Identity",
      body: """
      # Dispatch Lineage

      Every agent in loopctl operates under a dispatch — a scoped assignment
      with an ephemeral API key that carries its full lineage path.

      ## The dispatch tree

      ```
      root (operator, WebAuthn)
      ├── orchestrator dispatch (ephemeral key, 4h TTL)
      │   ├── implementer dispatch (ephemeral key, 1h TTL, story-scoped)
      │   └── reviewer dispatch (ephemeral key, 1h TTL, story-scoped)
      └── admin dispatch (ephemeral key, 1h TTL)
      ```

      ## Creating a dispatch

      ```bash
      curl -X POST https://loopctl.com/api/v1/dispatches \\
        -H "Authorization: Bearer $ORCH_KEY" \\
        -d '{"role": "agent", "agent_id": "...", "story_id": "...", "expires_in_seconds": 3600}'
      ```

      Response includes the ephemeral `raw_key` — pass it to the sub-agent.

      ## Lineage path

      Each dispatch records its full ancestry: `[root_id, orch_id, self_id]`.
      The self-check compares lineage prefixes: if two dispatches share a
      common ancestor (prefix), they are treated as the same actor.

      ## Why this prevents sock-puppets

      An orchestrator cannot dispatch a sub-agent and pre-select it as its
      own verifier. The rotating verifier selection (US-26.2.2) picks from
      dispatches that do NOT share a prefix with the implementer's lineage.

      See [Agent Pattern](/wiki/agent-pattern) for the full lifecycle.
      See [Capability Tokens](/wiki/capability-tokens) for how caps bind to lineages.
      """
    },
    %{
      slug: "verify-story",
      title: "Verify Story — The Verifier's Walkthrough",
      body: """
      # Verify Story

      This guide walks a verifier through the complete verification flow.

      ## Prerequisites

      - You hold a `verify_cap` for the story (issued by request_review)
      - Your dispatch lineage does NOT share a prefix with the implementer's
      - The story has a review_record confirming the review passed

      ## Step 1: Find stories awaiting verification

      ```bash
      curl -H "Authorization: Bearer $VERIFY_KEY" \\
        "https://loopctl.com/api/v1/stories?verified_status=unverified&agent_status=reported_done"
      ```

      ## Step 2: Review the acceptance criteria

      ```bash
      curl -H "Authorization: Bearer $VERIFY_KEY" \\
        "https://loopctl.com/api/v1/stories/STORY_ID/acceptance_criteria"
      ```

      ## Step 3: Re-execute verification

      For each AC with a `test` or `code` criterion, the verification runner
      checks the actual code/tests. For `manual` criteria, operator approval
      is required.

      ## Step 4: Submit verification

      ```bash
      curl -X POST -H "Authorization: Bearer $VERIFY_KEY" \\
        -d '{"summary": "All ACs verified", "cap_id": "..."}' \\
        "https://loopctl.com/api/v1/stories/STORY_ID/verify"
      ```

      See [Agent Pattern](/wiki/agent-pattern) for the full lifecycle.
      """
    },
    %{
      slug: "break-glass",
      title: "Break Glass — Emergency Override Procedures",
      body: """
      # Break Glass

      In rare cases, the chain-of-custody invariants may need to be overridden.
      This article documents the emergency procedures.

      ## When to use break-glass

      - All authenticators for a tenant are lost
      - The audit chain is corrupted and cannot be repaired
      - A tenant is halted due to a false-positive divergence detection

      ## Clearing a custody halt

      ```bash
      POST /api/v1/admin/tenants/:id/clear-halt
      ```

      Requires a fresh WebAuthn assertion from a root authenticator.

      ## Key recovery

      If the Fly secret containing the audit signing key is deleted, contact
      the loopctl maintainer. Recovery requires:
      1. Proof of tenant ownership (WebAuthn assertion)
      2. A new keypair generation
      3. A key-rotation audit entry signed by the new key
      4. Manual update of the Fly secret

      This is intentionally difficult — it represents a total compromise of
      the trust anchor.

      See [Tenant Signup](/wiki/tenant-signup) for normal key management.
      """
    },
    %{
      slug: "acceptance-criteria-bindings",
      title: "Acceptance Criteria Bindings — Machine-Checkable Verification",
      body: """
      # Acceptance Criteria Bindings

      Each acceptance criterion on a story can have a machine-checkable
      `verification_criterion` that tells the verification runner exactly
      what to check.

      ## Criterion types

      ### test
      ```json
      {"type": "test", "path": "test/my_module_test.exs", "test_name": "creates a record"}
      ```
      The runner executes the specific test and checks it passes.

      ### code
      ```json
      {"type": "code", "path": "lib/my_module.ex", "line_range": [10, 50], "pattern": "def create"}
      ```
      The runner checks that the specified pattern exists in the file.

      ### route
      ```json
      {"type": "route", "method": "POST", "path": "/api/v1/stories/:id/verify"}
      ```
      The runner checks that the route exists in the router.

      ### migration
      ```json
      {"type": "migration", "table": "dispatches", "column": "lineage_path"}
      ```
      The runner checks that the column exists on the table.

      ### manual
      ```json
      {"type": "manual", "description": "Operator must visually inspect the UI"}
      ```
      Requires human approval via the manual review dashboard.

      See [Verify Story](/wiki/verify-story) for how verification works end-to-end.
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
        '{"authored_by": "epic_26_phase_3"}',
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
  end

  def down do
    for article <- @articles do
      execute("DELETE FROM articles WHERE scope = 'system' AND slug = '#{article.slug}'")
    end
  end

  defp escape_sql(text) do
    String.replace(text, "'", "''")
  end
end
