defmodule Loopctl.Repo.Migrations.SeedEpic26Phase0Articles do
  use Ecto.Migration

  # Stub articles for slugs referenced by the discovery endpoint
  # and error responses. Full content is authored in US-26.3.3.
  @stub_articles [
    %{
      slug: "capability-tokens",
      title: "Capability Tokens",
      category: "reference",
      body: """
      # Capability Tokens

      _Full content for this article will be authored in US-26.3.3 (Phase 3)._

      Capability tokens are signed, scoped, non-replayable authorization
      tokens that gate custody-critical operations (report, review, verify).
      See the [Chain of Custody](/wiki/chain-of-custody) overview for context.
      """
    }
  ]

  @articles [
    %{
      slug: "chain-of-custody",
      title: "Chain of Custody — Trust Model Overview",
      category: "reference",
      body: """
      # Chain of Custody — Trust Model Overview

      loopctl's chain of custody prevents two failure modes in AI-agent-driven
      development: **sneaky agents** that bypass review to self-approve their own
      work, and **lazy agents** that declare incomplete work done.

      ## The two threat profiles

      ### The sneaky adversary

      An agent that appears to follow the process but exploits structural gaps to
      mark its own work as reviewed and verified. Examples: minting a second API
      key and using it as its own reviewer, passing nil identity to bypass
      comparison checks, or manipulating dispatch lineage so the verifier shares
      an ancestor with the implementer.

      ### The lazy adversary

      An agent that genuinely performs incomplete work — skipping tests, writing
      stub implementations, or declaring done without verifying acceptance
      criteria — then self-reports success. The work looks complete on paper but
      fails in production.

      ## The six-layer enforcement stack

      loopctl addresses both threats via six complementary layers:

      ```
      L0  Human + hardware anchor (WebAuthn at signup)
      L1  Capability tokens (signed, scoped, non-replayable)
      L2  Database invariants (FK, CHECK, triggers, partial indexes)
      L3  Independent re-execution (SWE-bench-style verification)
      L4  Structural role separation (dispatch lineage, rotating verifier)
      L5  Behavioral detection (lazy-bastard score, CoT sanity monitor)
      L6  Halt on byzantine conditions (divergent STH, custody halt)
      ```

      Each layer is independently useful and fails safe — if one layer is
      bypassed, the next catches the violation.

      ## Design principles

      - **Structural over policy**: Enforcement is in the database, not in code
        comments or documentation. A constraint violation crashes the transaction,
        not a log entry.
      - **Nil is never permissive**: Unknown identity is treated as untrusted, not
        as "no identity to compare."
      - **Independent re-execution beats self-reporting**: The system verifies work
        by re-running tests, not by trusting the agent's claim.
      - **Honest work is the path of least resistance**: The happy path (do real
        work, report it, get verified) is easier than any bypass attempt.

      ## Related articles

      - [Agent Bootstrap](/wiki/agent-bootstrap) — getting started from zero
      - [Agent Pattern](/wiki/agent-pattern) — the full agent lifecycle
      - [Tenant Signup](/wiki/tenant-signup) — the human root of trust
      - [Discovery](/wiki/discovery) — the `.well-known/loopctl` contract
      """
    },
    %{
      slug: "agent-bootstrap",
      title: "Agent Bootstrap — From First Contact to First Story",
      category: "reference",
      body: """
      # Agent Bootstrap — From First Contact to First Story

      This guide walks a new agent through the complete bootstrap flow, from
      discovering the loopctl API to claiming its first story.

      ## Step 1: Discover the API

      Fetch the well-known discovery document:

      ```bash
      curl https://loopctl.com/.well-known/loopctl
      ```

      The response tells you:
      - `spec_version` — the protocol version (currently `"2"`)
      - `mcp_server` — how to install the MCP server for Claude Code
      - `system_articles_endpoint` — where to find documentation
      - `audit_signing_key_url` — URI template for tenant public keys

      ## Step 2: Install the MCP server

      ```bash
      npm install loopctl-mcp-server
      ```

      Configure it in your Claude Code settings with your API key.

      ## Step 3: Authenticate

      Your orchestrator provides an API key. Use it as a Bearer token:

      ```bash
      curl -H "Authorization: Bearer lc_YOUR_KEY" \\
        https://loopctl.com/api/v1/projects
      ```

      ## Step 4: Find ready stories

      ```bash
      curl -H "Authorization: Bearer lc_YOUR_KEY" \\
        "https://loopctl.com/api/v1/projects/PROJECT_ID/stories/ready"
      ```

      ## Step 5: Contract and claim a story

      Before implementing, you must contract (acknowledge the ACs) and then
      claim the story:

      ```bash
      # Contract
      curl -X POST -H "Authorization: Bearer lc_YOUR_KEY" \\
        -H "Content-Type: application/json" \\
        -d '{"story_title": "...", "ac_count": N}' \\
        "https://loopctl.com/api/v1/stories/STORY_ID/contract"

      # Claim
      curl -X POST -H "Authorization: Bearer lc_YOUR_KEY" \\
        "https://loopctl.com/api/v1/stories/STORY_ID/claim"
      ```

      ## Step 6: Implement and report

      Do your work, then request review. **You cannot report your own work as
      done** — the chain of custody requires a different agent identity to
      confirm completion.

      ## Related articles

      - [Chain of Custody](/wiki/chain-of-custody) — the trust model
      - [Agent Pattern](/wiki/agent-pattern) — the full lifecycle
      - [Discovery](/wiki/discovery) — the `.well-known` contract
      """
    },
    %{
      slug: "agent-pattern",
      title: "Agent Pattern — Lifecycle and State Machine",
      category: "reference",
      body: """
      # Agent Pattern — Lifecycle and State Machine

      Every story in loopctl follows a strict lifecycle enforced by the API.
      This article describes the expected agent behavior at each stage.

      ## Story state machine

      ```
      pending → contracted → assigned → implementing → reported_done → verified
                                                          ↓
                                                       rejected → pending (retry)
      ```

      ## Lifecycle stages

      ### 1. Contract (pending → contracted)

      The agent reads the story's acceptance criteria and signals understanding
      by calling `POST /stories/:id/contract` with the exact title and AC count.
      This prevents silent misclaims.

      ### 2. Claim (contracted → assigned)

      `POST /stories/:id/claim` locks the story to the agent. Uses pessimistic
      locking to prevent double-claims.

      ### 3. Start (assigned → implementing)

      `POST /stories/:id/start` signals that implementation has begun.

      ### 4. Implement

      The agent writes code, tests, and documentation. Commits to a story
      branch, opens a PR.

      ### 5. Request review (implementing → implementing)

      `POST /stories/:id/request-review` fires a webhook so the reviewer
      knows to look. The agent's role ENDS here.

      ### 6. Report done (implementing → reported_done)

      A DIFFERENT agent calls `POST /stories/:id/report`. The API enforces
      `409 self_report_blocked` if the caller is the implementer.

      ### 7. Verify (reported_done → verified)

      The orchestrator calls `POST /stories/:id/verify` after confirming the
      review passed. Again, `409 self_verify_blocked` if the caller implemented
      the story.

      ## Chain of custody rules

      - Nobody marks their own work as done
      - Nobody verifies their own implementation
      - Each transition requires a specific role
      - Every transition is audit-logged

      ## Related articles

      - [Chain of Custody](/wiki/chain-of-custody) — the trust model
      - [Agent Bootstrap](/wiki/agent-bootstrap) — getting started
      """
    },
    %{
      slug: "tenant-signup",
      title: "Tenant Signup — WebAuthn Enrollment Ceremony",
      category: "reference",
      body: """
      # Tenant Signup — WebAuthn Enrollment Ceremony

      Every loopctl tenant begins with a human operator enrolling a hardware
      authenticator. This ceremony is the Layer 0 anchor of the chain of
      custody — without it, the entire trust model degrades to policy
      enforcement.

      ## Requirements

      - A FIDO2-compatible authenticator: YubiKey, Touch ID, Windows Hello,
        or any device implementing the WebAuthn standard
      - A modern browser with WebAuthn support (Chrome 67+, Firefox 60+,
        Safari 14+, Edge 79+)

      ## The ceremony

      1. Visit `https://loopctl.com/signup`
      2. Enter your tenant name, slug, and contact email
      3. Click "Enroll authenticator" — your browser prompts for a physical
         touch on your YubiKey or biometric confirmation
      4. The server verifies the FIDO2 attestation cryptographically
      5. Optionally enroll up to 4 backup authenticators in the same session
      6. Submit — the tenant is created atomically with:
         - The tenant record (status: active)
         - Root authenticator record(s)
         - An ed25519 audit-signing keypair
         - The genesis audit chain entry

      ## Audit-signing keypair

      At signup, loopctl generates an ed25519 keypair:
      - **Public key** stored on the tenant record (visible via API)
      - **Private key** stored as a Fly.io secret (never in the database,
        never accessible to agents)

      This keypair signs every Signed Tree Head (STH) and capability token
      for the tenant's audit chain.

      ## Key rotation

      The audit key can be rotated via `POST /tenants/:id/rotate-audit-key`.
      Rotation requires a fresh WebAuthn assertion — agents cannot rotate keys.

      ## Recovery

      If all authenticators are lost and the Fly secret is deleted, tenant
      recovery requires out-of-band contact with the loopctl maintainer.
      This is intentionally difficult — it represents a total compromise of
      the trust anchor.

      ## Related articles

      - [Chain of Custody](/wiki/chain-of-custody) — the trust model
      - [Discovery](/wiki/discovery) — the `.well-known` contract
      """
    },
    %{
      slug: "discovery",
      title: "Discovery — The .well-known/loopctl Contract",
      category: "reference",
      body: """
      # Discovery — The .well-known/loopctl Contract

      Following RFC 8615, loopctl publishes a discovery document at a
      well-known URL that agents and integrations can fetch without prior
      configuration.

      ## Endpoint

      ```
      GET https://loopctl.com/.well-known/loopctl
      ```

      No authentication required. Returns `application/json`.

      ## Response schema

      ```json
      {
        "spec_version": "2",
        "mcp_server": {
          "name": "loopctl-mcp-server",
          "npm_version": "2.0.0",
          "repository_url": "https://github.com/mkreyman/loopctl/..."
        },
        "audit_signing_key_url": "https://loopctl.com/api/v1/tenants/{tenant_id}/audit_public_key",
        "capability_scheme_url": "https://loopctl.com/wiki/capability-tokens",
        "chain_of_custody_spec_url": "https://loopctl.com/wiki/chain-of-custody",
        "discovery_bootstrap_url": "https://loopctl.com/wiki/agent-bootstrap",
        "required_agent_pattern_url": "https://loopctl.com/wiki/agent-pattern",
        "system_articles_endpoint": "https://loopctl.com/api/v1/articles/system",
        "contact": "operator@loopctl.com"
      }
      ```

      ## Caching

      The response includes `Cache-Control: public, max-age=3600` and a weak
      `ETag`. Agents should cache the document for the duration of their session
      (typically 1 hour) and use conditional GET (`If-None-Match`) to refresh.

      ## URL stability

      All URL fields are hardcoded to `https://loopctl.com` — they do NOT
      change based on the request's `Host` header. This ensures agents
      always reach the canonical deployment.

      ## URI templates

      The `audit_signing_key_url` uses a URI template (`{tenant_id}`). Agents
      substitute their tenant ID after authentication to construct the full URL.

      ## Schema validation

      A JSON Schema for the discovery document is available at:

      ```
      GET https://loopctl.com/.well-known/loopctl/schema.json
      ```

      ## Related articles

      - [Agent Bootstrap](/wiki/agent-bootstrap) — what to do after discovery
      - [Chain of Custody](/wiki/chain-of-custody) — the trust model
      """
    }
  ]

  def up do
    for article <- @stub_articles ++ @articles do
      # Use ON CONFLICT for idempotency
      execute("""
      INSERT INTO articles (id, tenant_id, scope, slug, title, body, category, status, metadata, tags, inserted_at, updated_at)
      VALUES (
        gen_random_uuid(),
        NULL,
        'system',
        '#{article.slug}',
        '#{escape_sql(article.title)}',
        '#{escape_sql(article.body)}',
        '#{article.category}',
        'published',
        '{"authored_by": "epic_26_phase_0"}',
        '{}',
        NOW(),
        NOW()
      )
      ON CONFLICT (slug) WHERE scope = 'system'
      DO UPDATE SET
        title = EXCLUDED.title,
        body = EXCLUDED.body,
        category = EXCLUDED.category,
        metadata = EXCLUDED.metadata,
        updated_at = NOW()
      """)
    end
  end

  def down do
    for article <- @stub_articles ++ @articles do
      execute("DELETE FROM articles WHERE scope = 'system' AND slug = '#{article.slug}'")
    end
  end

  defp escape_sql(text) do
    String.replace(text, "'", "''")
  end
end
