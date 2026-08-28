# Context Retriever (Epic 30)

Authoritative reference for loopctl's **Context Retriever** — the governed,
auto-generated agent query surface over loopctl's own STRUCTURED records
(`projects` / `stories` / `epics`). It is one of loopctl's four agent
information layers, alongside the Knowledge Wiki, Agent Memory and the Corpus
tier (Epic 43).

> loopctl is **agent-native**: there is **no web UI, no LiveView, no human login**
> for the Context Retriever. Entity definitions are authored and queries are run
> entirely over the **API / MCP** by keys the tenant already holds. Operator
> oversight is the superadmin-gated API path, not an admin console.

---

## The four-layer mental model (decide fast)

loopctl gives an agent four distinct places to get information. Pick by **what
the data IS**, not by "where will I find it later":

| Layer | What it holds | Scope / owner | Lifecycle | Reach it via |
|-------|---------------|---------------|-----------|--------------|
| **Knowledge Wiki** | Curated, *shared* tenant knowledge — patterns, decisions, findings, references (documents) | Tenant (with per-article agent visibility) | Human/agent-curated, versioned, linked, conflict-resolved | `knowledge_*` tools / `/api/v1/knowledge*` |
| **Agent Memory** | An agent subject's *private* working memory — session turns + long-term facts about *its* work | `(tenant, subject_id)` — one agent | Append/embed/supersede/forget; session tier expires (auto-accumulated) | `memory_*` tools / `/api/v1/memory*` |
| **Context Retriever** | *Governed, structured* access to *live business data* — rows in loopctl's own tables, exposed as typed, allowlisted entities | Tenant, schema-scoped | Read-through over the operational store; entity definitions are admin-authored | `retrieve_*` (generated `cr_*`) tools / `/api/v1/entities*` + `/api/v1/retrieve/*` |
| **Corpus tier** (Epic 43) | An index over *reference documents* whose files stay in the client's own repo — VERBATIM chunks, never distilled | Tenant, per corpus | Indexed from the client's files; a corpus pins its own dimension and is re-indexed, never edited in place | `corpus_*` tools / `/api/v1/corpora*` |

Rules of thumb:

- **Is it worth another agent reading?** → Knowledge Wiki (`knowledge_create`).
  Shared, curated, deduped by the novelty gate.
- **Is it a fact THIS agent learned about ITS task/user that only it needs to
  recall later?** → Agent Memory (`memory_remember`). Private to the subject,
  auto-accumulated.
- **Is it live operational state (a story, a project, an epic) you'd query by a
  structured filter or full-text search?** → the Context Retriever
  (`retrieve_*`). It reads loopctl's real rows through a governed, parameterized,
  tenant-scoped query — never free-form SQL.
- **Do you need the EXACT WORDING of an authoritative document — a spec, a
  contract, an RFC, a manual?** → the Corpus tier (`corpus_search`). It answers
  with a POINTER plus a bounded snippet (`{source_ref, locator, snippet, score}`),
  never the chunk body, so the next step is to open that file yourself. An empty
  `knowledge_search` says nothing about whether the document is indexed — check
  `corpus_list` before concluding it is not. See
  [`docs/user_stories/epic_43_corpus_tier/README.md`](user_stories/epic_43_corpus_tier/README.md).

This layering follows the "database as the agent's context layer, split into a
context-retriever + agent-memory" architecture (Cole Medin, *"I Love the Karpathy
LLM Wiki but it Doesn't Scale"*). loopctl sits on the **production** side of that
line: DB-backed, MCP-exposed, allowlist-governed — not a markdown second brain.
(KB hub: `fb9abd73`.)

> **Doc reconciliation (#309/#310):** the #309 body's "reconcile
> `docs/cole-medin-self-evolving-wiki.md`" item is **already satisfied** — that
> note was removed in PR #310 and its durable content now lives in the KB hub
> (`fb9abd73`) and in this document (single-home). The epic folder for this work
> is **`epic_30`**; the #309 body's `epic_29_context_retriever` label predates
> epic_29 being reassigned to Agent Memory Part 2 (#308).

---

## Architecture: entity → generator → executor

Three modules turn an admin-authored declaration into a safe agent query surface.

### 1. Entity registry — `Loopctl.ContextRetriever.Entity` / `Registry`

An **entity definition** is a tenant-admin-authored (role ≥ `user`, human-anchored)
declaration: a `name`, a `backing_source` (`:projects` / `:stories` / `:epics`),
and a list of typed `fields` (`%{name, type, filterable, searchable}`). It is
persisted in `entity_definitions` (tenant-scoped, RLS). **The definition IS the
executor's field allowlist** — it is attacker-authored, so a **SERVER-defined
per-source column allowlist** (`Entity.column_allowlist/0`, a code constant)
bounds which columns any entity may declare. `tenant_id`, `metadata`, and every
custody/dispatch/audit column are deliberately excluded. Per-tenant entity COUNT
is capped (`:max_entity_definitions_per_tenant`); fields-per-entity is capped
(`@max_fields`). Relationships/joins between entities are **out of scope for v1**
(no unvalidated relationship JSON is stored).

### 2. Tool generator — `Loopctl.ContextRetriever.ToolGenerator`

Reads a tenant's definitions and emits per-entity agent tool specs (`GET
/api/v1/retrieve/tools`): one `cr_filter_<entity>_by_<field>` tool per filterable
field, and one `cr_search_<entity>` tool when the entity declares a searchable
TEXT field that the source's `search_vector` actually covers. The tool schema puts
the filter value under the field-named key; `metadata` carries the
`{entity, field, operation}` dispatch tuple the executor consumes.

### 3. Executor — `Loopctl.ContextRetriever.Executor` (the security boundary)

`run/3` is the ONLY entry point. It takes a `Scope` (tenant + audit actor), the
`{entity, field, operation}` dispatch tuple, and the model-supplied params, and
returns a page of allowlisted-only result maps. **No model-authored SQL ever
reaches the database.** See the security model below.

The MCP layer (`mcp-server/lib/generated-tools.js`) calls the HTTP API, not the
contexts directly: it fetches `/retrieve/tools`, appends the `cr_*` specs to
ListTools (per-tenant, TTL-cached, negative-cached on outage), and dispatches a
`cr_*` call to `POST /api/v1/retrieve/:entity` under the SAME agent key as every
other read.

---

## Security model

The Context Retriever exposes live business data to a model-driven caller, so
every layer is fail-closed:

- **Server column allowlist** — an entity may only declare columns in
  `Entity.column_allowlist/0` for its source. This is the security gate:
  `tenant_id`, `metadata`, and custody columns can never be declared, so the
  "declared-fields-only" projection can never exfiltrate them. Adding a column is
  a security review, not a convenience.
- **Parameterization always** — filter values are Ecto-pinned (`^value`); search
  uses `websearch_to_tsquery('english', ?)`. An injection payload (`' OR 1=1 --`,
  `'; DROP TABLE stories; --`) becomes a **literal** that matches nothing — never
  SQL. An enum/decimal column whose pinned value fails re-cast returns
  `:no_match` (0 rows), never a DB error leak.
- **Dual tenant scoping** — every query runs under `Repo.with_tenant/2` (RLS
  `SET LOCAL app.current_tenant_id` + `SET LOCAL ROLE loopctl_app`, the **non-owner
  app role**, so RLS — `ENABLE`, not `FORCE` — actually engages) AND an explicit
  `where q.tenant_id == ^scope.tenant_id` predicate. `tenant_id` is read ONLY from
  the scope; any `tenant_id` in params is ignored.
- **Execute-time allowlist re-check** — generate-time checks bound the tool
  SURFACE, but a raw `POST /retrieve` can name a field the entity does not declare
  (or declares non-filterable/non-searchable). `run/3` RE-VALIDATES
  `(field, operation)` against the live definition AND the server allowlist and
  rejects with `{:error, :field_not_allowlisted}` (HTTP 422) — closing the
  raw-`/retrieve` bypass.
- **Result shaping** — results select ONLY the entity's declared, allowlisted
  columns (`map(q, ^declared_columns)`); never `SELECT *`, never
  `tenant_id`/`metadata`/custody columns.
- **Indexed search only** — search runs against the GIN-indexed, trigger-maintained
  `search_vector`; a declared-searchable column the vector does not cover is
  rejected with `:search_not_indexed` (422), never silently searched against the
  wrong columns.
- **Pagination + offset caps** — page size is clamped to
  `:context_retriever_max_page_size`; the offset is clamped to
  `:context_retriever_max_offset` (bounds the O(offset) deep-scan a model could
  otherwise trigger). No unindexed-scan DoS.
- **Audit, fail-closed** — every execution appends an `audit_log` entry
  (`entity_type: "context_retrieval"`) capturing tenant, actor,
  entity/field/operation, row count, and a SHA-256 digest of the params (raw
  values are NEVER stored — they may carry injection payloads / PII). If the audit
  insert fails, `run/3` FAILS CLOSED (`{:error, :audit_failed}`, no rows) — a
  read over business data is never disclosed without a persisted audit trail.
- **Rate limit** — `POST /retrieve/:entity` is per-tenant rate-limited
  (`cr_retrieve:tenant:<id>` bucket) BEFORE dispatch; over-limit is HTTP 429 and
  does NOT execute.
- **Role gate** — defining/mutating an entity requires role ≥ `user` AND a
  human-anchored tenant (the definition is a security root); querying
  (`/retrieve/*`, list, show) requires only authentication — `:agent` is the floor
  role, so the negative case for a query is **401** (unauthenticated), never a
  below-agent 403.
- **Fail-closed edges** — a `nil`-tenant (superadmin without impersonation) scope
  is refused (`:no_tenant`, never an `AdminRepo` cross-tenant read); a stale entity
  def (renamed/dropped backing column) surfaces as `:stale_entity` with no schema
  internals disclosed; a malformed call returns `:invalid_params` rather than
  raising.

---

## Surfaces

| Operation | Context (`Loopctl.ContextRetriever`) | HTTP API | MCP tool | Role |
|-----------|--------------------------------------|----------|----------|------|
| Define entity | `Registry.create_entity/3` | `POST /api/v1/entities` | *(API/MCP-authored; via the HTTP surface)* | user + human-anchor |
| List entities | `Registry.for_tenant/1` | `GET /api/v1/entities` | — | agent |
| Show entity | `Registry.get_entity_by_id/2` | `GET /api/v1/entities/:id` | — | agent |
| Update entity | `Registry.update_entity/4` | `PATCH /api/v1/entities/:id` | — | user + human-anchor |
| Delete entity | `Registry.delete_entity/3` | `DELETE /api/v1/entities/:id` | — | user + human-anchor |
| List generated tools | `Registry.tool_specs/1` | `GET /api/v1/retrieve/tools` | *(drives ListTools)* | agent |
| Execute filter/search | `Executor.run/3` | `POST /api/v1/retrieve/:entity` | `cr_filter_*` / `cr_search_*` (generated) | agent |

The MCP `retrieve_*` surface is **dynamic**: there are no static `cr_*` tool
names. The MCP client fetches the tenant's specs from `/retrieve/tools` and
appends them to ListTools per-tenant; a `cr_`-prefixed call is dispatched
generically to `POST /retrieve/:entity`. Specs that are not `cr_`-prefixed or that
collide with a static tool name are dropped (no description-spoofing). All queries
carry the same agent key as the tenant's other reads — the MCP server never holds
a stronger key for this path. The MCP tools expose **no** `tenant_id` parameter,
so a cross-tenant read is not even expressible there.

The `/retrieve` request body is `{"op": "filter"|"search", "field", "value",
"query", "limit", "offset"}`; `op` is matched to an atom without
`String.to_atom` on model input. The response is `{"results": [...], "meta":
{total_count, limit, offset}}`.

Endpoint specs (`OpenApiSpex operation/2`) render at `/swaggerui`.

---

## Verification (US-30.7, terminal)

- **End-to-end** (`Loopctl.E2E.ContextRetrieverJourneyTest`, `@tag :e2e`): an
  entity with a filterable AND a searchable field is defined via the API (user
  key); BOTH generated tools appear via `GET /retrieve/tools` (agent key); a
  FILTER query and a SEARCH query run via `POST /retrieve/:entity` — using the
  request body the MCP client derives from the tool spec AND a direct-API body —
  return the SAME tenant-scoped result set.
- **Terminal security** (`Loopctl.E2E.ContextRetrieverSecurityTest`, `@tag :e2e`,
  run under the non-owner app role): injection payloads in both a filter value AND
  a search query match literally (positive control proves the value is genuinely
  matchable); a non-allowlisted field is rejected on every surface (define-time
  422, execute-time 422); cross-tenant define/list/query isolation holds via
  context, API, and MCP-equivalent path (with a positive control); only declared
  columns are returned (no `tenant_id`/`metadata` leak); an `audit_log` record
  exists per execution; over-limit `/retrieve` is 429.
- **MCP dynamic listing + dispatch**
  (`mcp-server/test/context_retriever_tools.test.js`, `node --test`): ListTools
  appends the generated specs, `cr_*` calls dispatch to the right
  `POST /retrieve/:entity` body, tenant scoping / degrade-to-static / auth parity.

Run: `mix test.e2e` (or `E2E_TESTS=1 mix test test/e2e/context_retriever_*_test.exs`)
plus `cd mcp-server && npm test`. The per-unit suites
(`test/loopctl/context_retriever/*`, `test/loopctl_web/controllers/context_retriever_controller_test.exs`)
run in the default `mix test`.
