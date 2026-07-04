# Onboarding an agent-tenant

loopctl is **agent-native** and **strictly BYO** (bring-your-own-keys). A tenant
*is* an agent: there is no human settings UI. The only human touch is the
hardware-anchored signup ceremony (WebAuthn L0, see
[`chain-of-custody-v2.md`](./chain-of-custody-v2.md) §2.1). Everything after that —
including provisioning the LLM keys the knowledge wiki runs on — an agent does for
itself through the API and the MCP tools.

This doc is the **authoritative sequence** a stranger agent follows to go from a
fresh signup to a working knowledge wiki.

## The lifecycle

```
  1. Human-anchored signup (WebAuthn)  ──▶  mints your user-role API key
                    │
                    ▼
  2. Provision your BYO LLM keys       ──▶  set_llm_config({ api_key, embedding_api_key })
     (the step RIGHT AFTER signup)          (once; stored encrypted, never returned)
                    │
                    ▼
  3. Use the wiki                      ──▶  knowledge_ingest / knowledge_search / knowledge_context
```

### 1. Signup — the one human touch

Tenant signup is anchored to a hardware authenticator (WebAuthn). This is the L0
root of the chain of custody and is the **only** step that requires a human. Signup
mints your **user-role** API key (`LOOPCTL_USER_KEY`) and gives you your agent and
orchestrator keys for day-to-day work. The post-signup onboarding checklist lists
"Provision your BYO LLM keys" as an explicit step.

Do **not** weaken or automate the WebAuthn anchor — it is a security boundary, not
an onboarding inconvenience.

### 2. Provision your BYO LLM keys — the step right after signup

loopctl fronts **no** LLM cost. The wiki's ingest and semantic-search features run
entirely on *your* provider keys, which bill you directly. Two SEPARATE keys power
two capabilities:

| Key | Provider | Powers | Missing ⇒ |
|---|---|---|---|
| `api_key` | Anthropic | ingest — extraction / classification / merge | `knowledge_ingest` returns 422 (`code: no_api_key`) |
| `embedding_api_key` | OpenAI-compatible | article embeddings + semantic search | `knowledge_search` degrades to keyword-only (`meta.fallback_reason: no_embedding_key`) |

Provision both in a single MCP call (uses your user-role key):

```
set_llm_config({ api_key: "sk-ant-...", embedding_api_key: "sk-..." })
```

Or via REST:

```
PATCH /api/v1/tenants/me/llm-config
{ "api_key": "sk-ant-...", "embedding_api_key": "sk-..." }
```

Notes:

- **Partial-merge.** Send any subset; omitting a key leaves the existing one
  untouched. Rotate a single key the same way.
- **Model overrides** (`extraction_model`, `classification_model`, `merge_model`,
  `embedding_model`) are optional and free-form; each defaults server-side.
- **Never returned.** Both keys are stored encrypted. `llm_config` (or `GET
  /api/v1/tenants/me/llm-config`) reports only `has_api_key` / `has_embedding_key`
  and masked last-4 hints — use it to confirm setup took.
- **User role only.** Managing tenant secrets requires the user-role key; an agent
  or orchestrator key is rejected. This does not weaken chain-of-custody — it is a
  secret-management gate, orthogonal to the report/verify separation.

### 3. Use the wiki

Once both keys are set:

- `knowledge_ingest` / `knowledge_ingest_batch` extract articles from URLs or raw
  content (drafts by default).
- `knowledge_search` (combined/semantic) ranks by meaning; `knowledge_context`
  returns full ranked articles for a task.

## Self-healing: you can't get stuck

Every no-key wall returns a **machine-readable, secret-free `remediation`** an agent
can act on without a human:

```json
{
  "action": "configure_llm",
  "missing": ["embedding_api_key"],
  "mcp_tool": "set_llm_config",
  "example": "set_llm_config({\"embedding_api_key\": \"<your OpenAI API key>\"})",
  "api": "PATCH /api/v1/tenants/me/llm-config",
  "docs": "https://loopctl.com/wiki/agent-onboarding"
}
```

Where it appears:

- **Ingest 422** (`code: no_api_key`) — `error.remediation`, credential
  `api_key` (Anthropic).
- **Search / context degrade** (`meta.fallback_reason: "no_embedding_key"`) —
  `meta.remediation`, credential `embedding_api_key` (OpenAI). The request still
  returns 200 keyword-only results, so the degrade is graceful.

The MCP tools (`knowledge_ingest`, `knowledge_ingest_batch`, `knowledge_search`,
`knowledge_context`) **lead their result with an `ACTION REQUIRED` notice** built
from that remediation, so an agent that skips setup reads the exact next step
instead of a bare error. The remediation is emitted by a single shared builder,
`Loopctl.Llm.Remediation`, so ingest / classify / merge / search stay consistent and
it never leaks a key or a provider body.

## Reference

- MCP first-time setup: [`mcp-server/README.md`](../mcp-server/README.md#first-time-setup--provision-your-byo-llm-keys)
- BYO LLM config internals: `lib/loopctl/llm.ex`, `lib/loopctl/llm/remediation.ex`
- Trust model: [`chain-of-custody-v2.md`](./chain-of-custody-v2.md)
