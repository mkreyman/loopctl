# Agent Memory (Epics 28–29)

Authoritative reference for loopctl's **agent-memory** subsystem: what it is, the
two tiers, the scope/isolation model, when to reach for it vs the Knowledge Wiki
(vs the Context Retriever, vs the Corpus tier), its PII/secret stance, and the
**auto-promotion lifecycle** (Epic 29 / Part 2) that compiles session turns into
durable long-term memories.

> loopctl is **agent-native**: there is **no web UI, no LiveView, no human login**
> for memory. Every memory operation is an API/MCP call made by an agent under its
> own key. Operator oversight is the **superadmin-gated API path** (see
> [Operator oversight](#operator-oversight)), not an admin console.

---

## The four-layer mental model (decide fast)

loopctl gives an agent four distinct places to put/get information. Pick by
**ownership + lifecycle**, not by "where will I find it later":

| Layer | What it holds | Scope / owner | Lifecycle | Reach it via |
|-------|---------------|---------------|-----------|--------------|
| **Knowledge Wiki** | Curated, *shared* tenant knowledge — patterns, decisions, findings, references | Tenant (with per-article agent visibility) | Human/agent-curated, versioned, linked, conflict-resolved | `knowledge_*` tools / `/api/v1/knowledge*` |
| **Agent Memory** | An agent subject's *private* working memory — session turns + long-term facts about *its* work | `(tenant, subject_id)` — one agent | Append/embed/supersede/forget; session tier expires | `memory_*` tools / `/api/v1/memory*` |
| **Context Retriever** (Epic 30) | Governed, structured access to *live business data* (entities, not documents) | Tenant, schema-scoped | Read-through over the operational store; entity definitions are admin-authored | `retrieve_*` (generated `cr_*`) tools / `/api/v1/entities*` + `/api/v1/retrieve/*` |
| **Corpus tier** (Epic 43) | An index over *reference documents* whose files stay in the client's own repo — VERBATIM chunks, never distilled | Tenant, per corpus | Indexed from the client's files; a corpus pins its own dimension and is re-indexed, never edited in place | `corpus_*` tools / `/api/v1/corpora*` |

Rules of thumb:

- **Is it worth another agent reading?** → Knowledge Wiki (`knowledge_create`).
  It's shared, curated, and deduped by the novelty gate.
- **Is it a fact THIS agent learned about ITS task/user that only it needs to
  recall later?** → Agent Memory (`memory_remember`). It's private to the subject.
- **Is it live operational state (an order, a story, a ticket) you'd query by
  structured filters?** → the Context Retriever (`retrieve_*`), which reads
  loopctl's real rows through a governed, parameterized, tenant-scoped query. See
  [`docs/context-retriever.md`](context-retriever.md).
- **Do you need the EXACT WORDING of an authoritative document — a spec, a
  contract, an RFC, a manual?** → the Corpus tier (`corpus_search`). It answers
  with a POINTER plus a bounded snippet, never the chunk body, so the next step is
  to open that file yourself. An empty `knowledge_search` says nothing about
  whether the document is indexed — check `corpus_list` before concluding it is
  not. See
  [`docs/user_stories/epic_43_corpus_tier/README.md`](user_stories/epic_43_corpus_tier/README.md).

This layering follows the "database as the agent's context layer, split into a
context-retriever + agent-memory" architecture (Cole Medin, *"I Love the Karpathy
LLM Wiki but it Doesn't Scale"*). loopctl deliberately sits on the **production**
side of that line: DB-backed, MCP-exposed, semantically-retrieved — not a
markdown second brain. (KB hub: `fb9abd73` / `3ee5f890`.) The durable content of
the retired `docs/cole-medin-self-evolving-wiki.md` note lives in that KB hub and
in this document.

---

## The two tiers

Agent Memory has **two persistence substrates**, kept strictly separate from the
Knowledge Wiki `articles` table.

### 1. Session memory (short-term) — `session_memories`

- **Append-only** working memory of a single agent *session*: turns and facts.
- Row = `{session_id, role, content, metadata, expires_at}`. `role` ∈
  `:user | :assistant | :system | :fact`.
- **No embedding** — read *chronologically*, not by similarity. Ordering is
  deterministic via a `bigserial seq` tiebreaker (so same-microsecond appends are
  still totally ordered).
- **TTL + pruning**: every row carries a required `expires_at`. The
  `Loopctl.Workers.SessionMemoryPruneWorker` (Oban) deletes expired rows on a
  schedule — session memory is *ephemeral by design* and self-cleans. `content`
  is byte-capped (100 KB) to bound footprint.
- Written with `tier: :session` (needs `session_id`, `content`, `expires_at`);
  read back in insertion order via `Loopctl.Memory.session_history/2`.

### 2. Long-term memory — `memories`

- **Durable facts/observations** an agent should recall across sessions.
- Row = `{text, embedding vector(1536), confidence, source, tags, metadata,
  superseded_by}`. `source` ∈ `:explicit` (agent-written, default) | `:promoted`
  (written by the Part-2 auto-promotion compiler; see [Seams](#seams-part-2--consumers)).
- **Embedded asynchronously**: `embedding` is `NULL` on insert; the
  `Loopctl.Workers.MemoryEmbeddingWorker` (Oban) populates it. Recall is an **HNSW
  cosine kNN** over the embedding.
- **Supersede, not mutate**: a newer memory supersedes an older one
  (`superseded_by` self-reference); superseded rows drop out of default recall/list
  but are retained (auditable, and surfaced with `include_superseded: true`).
- **`forget`** deletes outright, scoped to the owner.
- Per-`(tenant, subject)` **quota** (default 10 000 live rows) bounds the
  recallable tier; the write path is **rate-limited** and quota-checked in one
  advisory-locked transaction, so the cap is race-free.

---

## Scope & isolation model

Every memory row is owned by **`(tenant_id, subject_id)`** — this pair *is* the
isolation boundary.

### `subject_id` derivation (server-side, never client-supplied)

Resolved from the caller's authenticated API key by
`Loopctl.Memory.subject_id_for/1`:

- **agent-role key with a non-blank `agent_id`** → the `agent_id` (so every
  ephemeral key an agent rotates through shares ONE memory scope).
- **otherwise** (user/orchestrator/superadmin, or an agent key with no
  `agent_id`) → the API key's own `id`.

Any `tenant_id`/`subject_id`/`scope` in a request **body is ignored**. A key whose
subject cannot be resolved is refused with a deterministic `422`
(`subject_id_unresolvable`) — never a null-scoped write.

### The BYPASSRLS heavy-read structural guard

The `Loopctl.Memory` context reaches its tables ONLY through **BYPASSRLS** repos —
`Loopctl.AdminRepo` (OLTP: write/list/forget/supersede/session_history) and
`Loopctl.HeavyReadRepo` (recall kNN). **RLS does NOT engage on any of these
paths.** Isolation is therefore the **explicit `(tenant_id, subject_id)`
predicate** on every query — not an RLS backstop.

For recall specifically, the predicate is enforced *structurally* by
`Loopctl.HeavyRead.all_memory/4`, which **raises** unless the outermost query
carries a conjunctive `subject_id == ^subject_id` bound (and every base source is
tenant-scoped). This matters because the index-safe recall (below) deliberately
keeps `subject_id` OFF the inner ANN subquery — the guard guarantees no
cross-subject row can ever be *returned*.

### Index-safe recall (why the subject filter is on the OUTER query)

A selective `(tenant_id, subject_id)` btree on the inner index-ordered ANN
subquery would flip the planner OFF the pgvector HNSW index (#170/#172). So recall:

1. **Inner**: over-fetches a pool of `pool > k` nearest-by-cosine rows with only
   *index-safe* residuals (`tenant_id =`, `embedding IS NOT NULL`, and — on the
   default path — `superseded_by IS NULL`, served by the partial HNSW index
   `memories_live_embedding_hnsw_idx`).
2. **Outer**: applies the `subject_id` scope (and superseded exclusion) over the
   materialised pool.

`meta.underfilled` flags a short page. The terminal scale gate
(`Loopctl.Memory.ScaleRecallTest`, US-28.5 / AC-28.5.5) proves a needle subject
reliably recalls its OWN top-k among an ~80k-row multi-subject corpus — i.e. the
over-fetch pool + outer filter does not *starve* a subject at scale.

Step 1's `tenant_id` is a *residual* the index applies after returning its batch,
so a vector read that loses pgvector's `hnsw.iterative_scan` can under-return rows
this subject has — and `underfilled` cannot tell that apart from a sparse scope.
The semantic path therefore also returns `meta.ann_iterative_scan`
(`off` | `applied` | `unavailable`), plus `meta.ann_iterative_scan_reason`
alongside `unavailable` only. It is the *same* field, values and meaning
`/knowledge/search` returns (one derivation,
`Loopctl.HeavyRead.iterative_scan_meta/1`), and it is derived from the options
that read was issued with — never a fresh probe — so it cannot disagree with the
rows it accompanies. It speaks only to the filters iterative scan governs: step
2's `subject_id` sits outside the index scan, so subject dilution is bounded by
the over-fetch pool (measured by the scale gate above), is identical under
`applied` and `unavailable`, and remains `underfilled`'s job alone. Two reads
carry no such field because neither scans the index: the `ILIKE` fallback below,
and the `include_superseded` side-table read (an exact bounded top-k sort).

### Graceful degradation (never a silent empty)

When embedding generation is unavailable (circuit open / no per-tenant key /
provider error), recall falls back to a recent-first `ILIKE` text match **within
the same `(tenant_id, subject_id)` scope**, returning `meta.fallback: true` with a
stable `meta.reason` tag (and `score: null`). A legitimately empty scope on the
healthy path returns `[]` with `fallback: false, reason: nil` — the two
zero-result cases are distinguishable. The fallback path is *also* scope-isolated:
degradation never widens the blast radius.

### Operator oversight

There is no inspector UI. A **superadmin** key (tenant-less; supplies a tenant via
the `X-Impersonate-Tenant` header) may, over the API:

- **list every subject's** memories in a tenant — `GET /api/v1/memory?all_subjects=true`
  (`Loopctl.Memory.list_all_subjects/2`); and
- **delete any** memory in a tenant — `DELETE /api/v1/memory/:id`
  (`Loopctl.Memory.forget_any/2`).

Both require `X-Impersonate-Tenant` (else a deterministic `422`
`impersonation_tenant_required`). A non-superadmin's `all_subjects=true` is
ignored (confined to its own subject); a non-superadmin delete is confined to its
own subject. Oversight list/delete are **not** frozen by a tenant custody halt
(the operator retains visibility/control) even though agent *writes* are blocked
during a halt.

---

## Project scope — the `project_id` PARTITION key (#411)

Every memory row also carries an optional **`project_id`**. It **partitions** a
subject's memories into a **global** bucket (`project_id IS NULL` — tenant-wide,
cross-project) and one bucket **per project**. Crucially:

- **`project_id` is a PARTITION key, NOT the isolation boundary.** The isolation
  boundary is still `(tenant_id, subject_id)` — always key-derived, never
  body-supplied. `project_id` only narrows *which of the subject's own memories*
  a read sees; it can never cross the subject/tenant boundary.
- **Write** (`POST /api/v1/memory`): an absent/blank `project_id` writes a
  **global** memory; a present one partitions the memory to that project. On
  write, `project_id` **is** tenant-validated — a malformed value, or a
  well-formed UUID that is not a project in the caller's own tenant, is a `422`
  (`invalid_project_id`), never a silently mis-scoped row.
- **Recall** merges **`global ∪ active-project`**: an absent/blank `project_id`
  returns **global-only** memories; a present one returns the union of global +
  that project (another project's memories are excluded). Recall deliberately
  does **NOT** tenant-validate a well-formed `project_id` (it's a partition key
  there): a stale/typo/foreign UUID reads as an *empty partition* → your global
  rows only, with **no error** (the `(tenant, subject)` predicate still bounds
  every result). This asymmetry with write is intentional.

### Resolving a repo → `project_id` (`resolve_project`, #411 Gap 1)

Agents know their repo, not the project UUID. `Loopctl.Projects.resolve_project/2`
maps a `repo_url` / `slug` / `name` to a `project_id` in one cheap call:

| Surface | |
|---------|--|
| Context | `Loopctl.Projects.resolve_project/2` |
| HTTP | `GET /api/v1/projects/resolve?repo_url=…` (or `slug=` / `name=`) |
| MCP | `resolve_project` |

Precedence is `slug > repo_url > name`, first match wins; `repo_url` accepts
`git@github.com:owner/repo.git`, `https://github.com/owner/repo`, and bare
`owner/repo`. Returns the project (use its `id` to scope captures/recall), `404`
`not_found` if nothing matches, `422` `no_identifier` if none supplied, `409`
`ambiguous_resolution` if a fuzzy identifier matches more than one active project.

### Merged recall — `POST /api/v1/recall` (`recall_context`, #411 Gap 2)

One round-trip returning the re-ranked **`global ∪ active-project` union of
long-term MEMORY *and* KNOWLEDGE** — what a harness previously assembled by
calling `/memory/recall` and `/knowledge/search` separately.

| Surface | |
|---------|--|
| Context | `Loopctl.Memory.recall_context/2` |
| HTTP | `POST /api/v1/recall` `{query, project_id?, limit?}` |
| HTTP | `POST /api/v1/recall/:recall_id/referenced` `{article_ids, project_id?}` |
| MCP | `recall_context`, `recall_referenced` |

- The knowledge half is the **combined SEARCH** (article *summaries* —
  `{id, title, category, tags, score, snippet}`), **not** the deep-read
  `/knowledge/context` (full bodies + linked refs). Callers needing full bodies
  still call `/knowledge/context`.
- Response carries the merged `results` (each tagged `source: "memory" |
  "knowledge"`, sorted by a heuristically-comparable `score` DESC —
  `meta.results_ranking: "heuristic_cross_source"`) **plus** the untouched
  per-source `memory` and `knowledge` envelopes so callers can re-rank.
  Cross-source scores are heuristic, not calibrated.
- **Query validation up front**: a non-string / blank / whitespace-only `query`
  is `422` (`invalid_query`); a query longer than **500 characters** is `422`
  (`query_too_long`) — rejected *before* any embedding is generated, matching
  `/knowledge/search` (never a half-degraded memory-only 200).
- **Degraded path (never a 500):** if the knowledge side errors or degrades to
  keyword-only, OR the memory heavy-read pool is shed under the per-tenant cap,
  the *other* side is still returned with `meta.degraded?: true` (and
  `meta.degraded_reason` naming why). Agent-role keys are forced to **published**
  articles and their own/`shared` memories (#163).

#### The selection ledger

Borrowed from MemoRizz's per-turn `EvidencePack` (KB
`80a063e9-22b4-4469-9f1e-3be499a3fc2c`), which records candidates, supplied items
and referenced sources with rank, score and a token budget. The point is that a
client can **explain its own context assembly** instead of inferring it from the
list it happened to get.

Per merged `data` item:

| Field | |
|-------|--|
| `rank` | 1-based position in the MERGED list, not the per-source rank |
| `selection_reason` | knowledge: `keyword`, `semantic`, `keyword+semantic`, `keyword_fallback`, `unscored`; memory: `semantic`, `ilike_fallback` |
| `tokens_estimate` | bytes/4 of the text a client would paste — an **estimate**, never a tokenizer count |

In `meta`: `recall_id`, `candidates_considered` (`{memory, knowledge, total}`
before the merged cap), `selected_count`, `tokens_selected`, `tokens_candidates`
and `tokens_saved_vs_candidates`.

The merged order is **deterministic** — score DESC, then source (`knowledge`
before `memory`), then id ASC — so an unchanged corpus renders a byte-identical
`data` array between turns. Cache THAT array, not the whole envelope:
`meta.recall_id` is minted per call, so two identical recalls always differ in
`meta`. Same discipline as the heat index snapping its default window to a UTC
day boundary for byte-identical refreshes.

#### `meta.recall_id` and the third funnel stage

`recall_id` is ONE id for the whole recall, and it is the `search_id` stamped on
the knowledge half's surfacing rows in `article_access_events` — not a second id
that has to be joined to the first. Hand it back:

    POST /api/v1/recall/:recall_id/referenced   {"article_ids": [...]}

That records `access_type: "referenced"` rows with `origin_search_id =
recall_id` — the stage nothing measured before. Surfaced and opened were both
observations; this one is a **client assertion**, so it is bounded rather than
trusted:

- only articles that recall **actually surfaced** under that `recall_id`, in the
  caller's own tenant, are accepted. Any other id fails the WHOLE call with `422`
  `not_surfaced` and nothing is written. An unknown or foreign `recall_id`
  surfaced nothing, so it takes the same 422 — there is no cross-tenant existence
  oracle;
- the recording key is the caller's, stamped server-side;
- at most 50 ids per call (`invalid_recall_id` / `invalid_article_ids` /
  `too_many_article_ids` are the other 422s);
- repeats are safe: `RetrievalMetrics` counts DISTINCT `(recall_id, article_id)`
  pairs, so posting twice cannot move `referenced` / `reference_rate`.

**A `referenced` row is in NO read set** — not `Analytics.@read_access_types`,
not `@attributable_access_types`, not `Knowledge.@heat_read_access_types`, not
`LiveRetrievalMetrics`' chosen reads. Heat and precision must never rank on a
signal a client asserts about itself.

---

## Graduation — HOT memory → durable knowledge (#411 Gap 3)

The tier *above* long-term memory. A long-term memory that has proven valuable —
recalled often enough — is written back into the **curated Knowledge Wiki** as a
durable article, DEDUPED by the same **novelty gate** (`propose_article/3`) that
guards every agent write-back.

**Visibility — graduated articles stay OWNER-visible, NOT peer-readable.** A memory
is agent-private working memory scoped by `(tenant_id, subject_id)`; graduation
deliberately stamps the article `metadata.visibility = "owner"` with
`agent_id = subject_id` (see `memory_to_article_attrs/2`) so it becomes *durable*
knowledge discoverable by the **owning subject** — it does NOT become tenant-wide
*shared* knowledge that every peer can find via `knowledge_search` (graduating into a
shared article would leak one agent's private memory to every peer in the tenant).
`re_scope: "global"` only widens the **project partition** (project → tenant-wide
`project_id: null`); it does NOT change visibility — the article remains owner-visible.

### Recall-count hotness signal (off the hot path)

Recall bumps a memory's `recall_count` (+ `last_recalled_at`) so "frequently
recalled = proven valuable" is measurable — but the bump is deliberately
conservative so the signal stays honest:

- **Off the hot path**: the bump is a fire-and-forget async write (bounded by
  `memory_recall_bump_max_tasks` = **200** concurrent tasks/node; over the cap it
  is simply dropped — best-effort, never blocks recall).
- **Relevance floor**: only a recall whose cosine similarity clears
  `memory_recall_bump_min_score` = **0.6** counts, so a sparse subject scope
  doesn't auto-inflate low-relevance noise.
- **Cooldown**: a given memory is bumped at most once per
  `memory_recall_bump_cooldown_seconds` = **3600** s, so a tight single-agent
  recall loop can't game graduation.
- The **degraded ILIKE fallback path never bumps** (keeps the hotness signal
  clean).

### The hourly sweep (`MemoryGraduationSweepWorker`)

`Loopctl.Workers.MemoryGraduationSweepWorker` runs **hourly** and graduates
not-yet-graduated (`graduated_at IS NULL`) memories at or above the recall
threshold:

- **Threshold** — `memory_graduation_recall_threshold` = **3** recalls.
- **Per-run budget** — at most `memory_graduation_max_per_run` = **50** memories
  graduated per tick.
- **Scan fan-out** — `memory_graduation_scan_limit` = **500** bounds the
  distinct-tenant scan; round-robin fairness keeps one busy tenant from starving
  others (worst-case candidate rows per tick ≈ `2 * max_per_run`, not
  `scan_limit * max_per_run`).
- Each candidate is graduated via the novelty gate and **stamped `graduated_at`**
  on any durable verdict, so it is never re-processed. A **fell-open** gate
  (embedding backend down) is NOT stamped — the memory re-graduates and dedups
  once embeddings recover. The sweep **never re-scopes** (a project memory
  graduates to a project article).

### Explicit, on-demand graduation (`memory_graduate`)

`Loopctl.Memory.graduate_memory/3` is the explicit per-memory trigger — the
on-demand version of the sweep, now reachable by agents:

| Surface | |
|---------|--|
| Context | `Loopctl.Memory.graduate_memory/3` |
| HTTP | `POST /api/v1/memory/graduate` `{memory_id, re_scope?}` |
| MCP | `memory_graduate` |

- Scope is key-derived — a caller may only graduate its **own** memory; a
  foreign/nonexistent `memory_id` is `404` (no cross-subject existence oracle). A
  malformed `memory_id` is `422` (`invalid_memory_id`).
- The novelty-gate `verdict` drives the status: `created` (novel → published) or
  `gated_to_draft` (near-duplicate → unpublished review draft) → **201** with a
  new article; `duplicate` / `deduplicated` (already represented → the canonical
  article, nothing created) → **200**. The response `data` carries
  `{verdict, created, article}` (a body-less article summary — fetch the full
  body via `GET /articles/:id`).
- **local→global re-scope**: by default the article inherits the memory's
  `project_id` (project memory → project article, global memory → global
  article). Pass `re_scope: "global"` to promote a **project** memory to a
  tenant-wide (`project_id: null`) article. This is the **only** way graduation
  re-scopes — the sweep never does, because over-generalizing a project fact to
  tenant-wide is a mis-scoping the novelty gate cannot catch.
- A memory has **at most one** graduated article (the `(tenant_id, title)` unique
  index). So `re_scope: "global"` on an already-graduated **project** memory returns
  `409` (`already_graduated`) rather than silently returning the wrong-scoped
  article. (On an already-graduated **global** memory `re_scope: "global"` is a
  no-op — same scope — so it dedups to `200`, not `409`.) An already-graduated memory
  short-circuits to its existing article **without re-running the novelty gate**, so
  repeated `memory_graduate` calls never re-spend assessment/embedding budget.
- **Globalization is a first-graduation race, and the caller cannot always beat it.**
  `re_scope: "global"` is the ONLY way a project memory becomes tenant-wide, and it
  only takes effect on the memory's FIRST graduation. But the **hourly sweep**
  graduates eligible memories **project-scoped** (it never re-scopes). If the sweep
  graduates a project memory before your on-demand call, `re_scope: "global"`
  permanently `409`s and that memory can no longer become tenant-wide via graduation.
  The window is bounded (a memory is only sweep-eligible once its `recall_count`
  reaches the threshold, and the sweep runs at most hourly), so **graduate promptly**
  when you intend to globalize; otherwise re-point the already-published article's
  scope as a separate curation action.
- The graduation race is serialized at the write: two concurrent FIRST graduations
  with differing `re_scope` cannot both win — the loser gets a deterministic `409`
  (`already_graduated`), never the wrong-scoped article as a `200`.
- If the gate falls open (embedding backend down) graduation returns `503`
  (`gate_unavailable`) and stamps nothing — retry once embeddings recover.

---

## PII / secret stance

**Memory text leaves the tenant boundary to a third-party embedding provider.**

Long-term memory `text` is embedded by a **per-tenant BYO** embedding provider
(the tenant supplies its own key — loopctl fronts no embedding cost). Producing
the embedding sends the memory content to that external API. Therefore:

- **Do NOT store secrets or regulated PII as memory text**: API keys, passwords,
  tokens, full payment card numbers, government IDs, or anything that must never
  transit a third-party API. If a fact references a secret, store a *pointer*
  ("the deploy key is in the vault under `prod/deploy`"), not the secret itself.
- Prefer durable *preferences, decisions, and observations about the work* —
  the things worth recalling — over raw sensitive data.
- The write path is **rate-limited** (API-layer `RateLimiter`) and **per-scope
  capped** (the per-`(tenant, subject)` live-row quota), so a runaway agent cannot
  exfiltrate unboundedly or exhaust storage.
- Session memory content is byte-capped and **auto-expires** (TTL prune), so
  transient turn data does not accumulate indefinitely.

This is the same BYO trust model as the Knowledge Wiki's LLM operations: content
that is embedded/processed leaves the boundary to the tenant's own provider, and
the tenant owns that exposure.

---

## Surfaces

| Operation | Context (`Loopctl.Memory`) | HTTP API | MCP tool |
|-----------|----------------------------|----------|----------|
| Write | `remember/2` | `POST /api/v1/memory` | `memory_remember` |
| Recall (semantic) | `recall/2` | `POST /api/v1/memory/recall` | `memory_recall` |
| Merged recall (memory ∪ knowledge) | `recall_context/2` | `POST /api/v1/recall` | `recall_context` |
| List (long-term) | `list/2` | `GET /api/v1/memory` | `memory_list` |
| Forget | `forget/2` | `DELETE /api/v1/memory/:id` | `memory_forget` |
| Promote (session → long-term) | `promote_session/1` | `POST /api/v1/memory/promote` | `memory_promote` |
| Graduate (memory → knowledge) | `graduate_memory/3` | `POST /api/v1/memory/graduate` | `memory_graduate` |
| Resolve repo → `project_id` | `Loopctl.Projects.resolve_project/2` | `GET /api/v1/projects/resolve` | `resolve_project` |
| Session history | `session_history/2` | — | — |
| Supersede | `supersede/3` | — | — |
| Oversight list/delete | `list_all_subjects/2` / `forget_any/2` | `?all_subjects=true` / `DELETE :id` (superadmin) | via `memory_list`/`memory_forget` |

The MCP layer calls the HTTP API (not the context). `session_history/2` and
`supersede/3` are context-level seams with no MCP tool. The memory-substrate MCP
tools expose **no** `tenant_id`/`subject_id` parameter, so a cross-scope read is
not even expressible there (scope is key-derived); only `project_id` — a
partition key, not the isolation boundary — is caller-supplied on the
project-aware surfaces.

Every read path returns the **pinned envelope**:

- `recall/2` → `%{results: [{memory, score} | ...], meta: %{total_count, fallback,
  reason, underfilled}}` (`score` is `nil` on the fallback path), plus
  `ann_iterative_scan` (and `ann_iterative_scan_reason` when `unavailable`) on the
  semantic path — see the index-safety section above.
- `list/2` / `session_history/2` / `list_all_subjects/2` → `%{results: [memory],
  meta: %{total_count, limit, offset}}`.

---

## Promotion lifecycle (Epic 29 / Part 2)

Part 2 (Epic 29, **shipped** — the compiler that Part 1 left as a seam is now real
production code) is the **auto-promotion** subsystem: it distills a session's
short-term turns into durable long-term `:promoted` memories WITHOUT an agent making
an explicit `memory_remember` call. It is agent-native and unattended — driven by an
hourly cron sweep and (optionally) a Claude Code Stop-hook — so every stage is
fail-closed, budget-bounded, idempotent, and injection-resistant.

### The pipeline: session → compile → confidence gate → hash dedupe/supersede → long-term

1. **Trigger.** Either explicit (`POST /api/v1/memory/promote {session_id}` →
   `Loopctl.Memory.promote_session/1`, `memory_promote` MCP tool) or the scheduled
   `Loopctl.Workers.MemoryPromotionSweepWorker` (all-tenants cron). Both enqueue the
   per-session `Loopctl.Workers.MemoryPromotionWorker`, unique per
   `(tenant_id, subject_id, session_id)` so an explicit + sweep race cannot
   double-promote.
2. **Watermark skip (idempotency spine).** The worker computes the session's
   content hash (`Loopctl.Memory.Promoter.session_fingerprint/2`) and compares it to
   the stored `session_promotions` watermark. Equal hash → the session is unchanged →
   **skip WITHOUT calling the LLM** (kills re-LLM-every-tick / paraphrase drift). A
   0/1-turn session is a no-op that does NOT even write a watermark (so junk sessions
   can't starve the budget). Emits `:skipped`.
3. **Compile.** `Loopctl.Memory.Promoter.compile/2` reads the scope-enforced
   `session_history/2` (a foreign tenant/subject reads empty → the LLM never sees
   foreign content), assembles the most-recent turn window, and calls the promoter
   LLM (temperature 0, `Loopctl.Memory.Promoter.LLMBehaviour`, BYO key) with a
   fail-closed parser.
4. **Confidence gate.** Each candidate is normalized, then dropped below
   `Loopctl.Memory.Promoter.confidence_threshold/0` and capped to
   `max_candidates/0`. The surviving candidates' `confidence` is carried onto the
   promoted memory (`confidence` column). Emits `:compiled` with the survivor count.
5. **Synchronous-hash dedupe / supersede.** `Loopctl.Memory.persist_promotion/2`
   writes each survivor as a `source: :promoted` memory, embedding it
   **synchronously at write time** (no async-embedding gap in which a paraphrase could
   slip past near-dup detection):
   - **Exact dedupe** — the `embedding_content_hash` (set at write time) hits the
     partial unique index `(tenant_id, subject_id, embedding_content_hash) WHERE
     source = :promoted`; an identical text is a no-op (`:gated_out`).
   - **Near-dup supersede** — a paraphrase above the near-dup threshold `supersede`s
     the prior `:promoted` row (new row live, old row's `superseded_by` set). Supersede
     is **source-scoped to `:promoted`** — it NEVER clobbers a human-authored
     `:explicit` memory. Emits `:promoted` / `:superseded`.
6. **Watermark advance.** On success (INCLUDING a zero-survivor run) the watermark is
   upserted so the next trigger skips. A compile/LLM `{:error, _}` does NOT advance it
   (retry re-attempts); degraded embeddings `{:snooze, _}`; a subject at its hard
   memory cap `{:discard, :quota_exceeded}` (watermark advanced, dropped-survivor count
   emitted so the loss is visible).

### Watermark + per-tenant budget + TTL-window invariant

- **Watermark** (`session_promotions`, unique on `(tenant_id, subject_id,
  session_id)`) is upserted on EVERY run incl. zero-survivor; both the explicit and the
  sweep trigger skip an unchanged session. This is the idempotency measure — proven by
  re-running promotion and counting `:promoted` rows **including superseded**
  (`superseded_by` NOT filtered): a re-promote must add zero net rows.
- **Per-tenant budget** — `Loopctl.Memory.promotion_budget/0` caps compiles/hour per
  tenant. The reservation is atomic under a per-tenant advisory lock and counts BOTH
  completed watermarks AND in-flight jobs (closes a TOCTOU overshoot). Over budget →
  `{:error, :budget_exceeded}` → **HTTP 429 with NO LLM call** (the gate precedes the
  compile). A worker-level re-check bails a burst's overshoot to cheap no-ops.
- **TTL-window invariant** — `sweep_interval < sweep_window < session_ttl` (asserted by
  `Loopctl.Memory.assert_promotion_ttl_invariant!/0`). The sweep promotes
  **oldest-active-first** so the session nearest its prune deadline is never starved
  behind newer ones — bounding the golden-nugget-loss window before session turns TTL
  out.

### Confidence threshold + promotion-quality eval (US-29.5)

The confidence gate is **calibration**, not a correctness oracle. US-29.5 ships a
labeled promotion-eval dataset (`priv/promotion_eval/dataset_v1.json`, ≥3 labeled
sessions plus an injection case whose expected label is "nothing durable") and
`Loopctl.Memory.PromotionEval`, which scores the compiler's precision/recall against
that ground truth and emits a `[:loopctl, :memory_promotion, :eval]` snapshot. It runs
under a **reserved eval subject** (`Loopctl.Memory.eval_subject_id/0`) that is
STRUCTURALLY excluded from real promotion — the sweep filter skips it AND
`persist_promotion/2` refuses it — so the eval's synthetic/injection turns can never
become durable memories. The eval **never gates** promotion; it is observability for
tuning the threshold. See [`docs/observability/promotion-eval.md`](observability/promotion-eval.md).

### Prompt-injection stance (unattended safety)

Promotion runs on untrusted session content with no human in the loop, so the model
output is treated as data, never instructions:

- **Session content is scope-enforced** — `compile/2` reads only the caller's
  `(tenant, subject, session)` turns; the LLM is never fed foreign content, and a
  foreign session compiles to `{:ok, []}` before any LLM call.
- **`cross_links` are tenant + visibility validated** (`validate_cross_links/2` →
  `Loopctl.Knowledge.visible_article_ids/3`). Even if a compromised model "obeys" an
  injected "link this article" instruction and emits a foreign-tenant or fabricated
  article id, that id is STRIPPED before write — a promoted memory can only ever link
  an article the compiling subject can actually see. No cross-tenant-linked poisoned
  memory is producible.
- **Fail-closed parser** — malformed model output never raises and never writes
  garbage; it yields no candidates.
- **Budget + quota bounds** cap the blast radius of a runaway/adversarial loop
  (429 pre-LLM, terminal discard at the subject cap).

### Claude Code Stop-hook recipe (cross-ref `mkreyman/claude-config#85`)

The unattended trigger is a Claude Code **Stop hook** that fires `memory_promote` for
the just-finished session when a coding session ends — turning "what the agent learned
this session" into durable memory without an explicit call. **The hook itself is NOT
implemented in loopctl** (`mkreyman/claude-config#85` owns it); loopctl documents and
asserts the seam. The recipe:

```jsonc
// ~/.claude/settings.json  (claude-config#85 — illustrative; the hook script lives there)
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            // The hook resolves $LOOPCTL_SESSION_ID for the finished session and calls the
            // MCP tool memory_promote { session_id }, which POSTs /api/v1/memory/promote.
            // It NEVER supplies tenant_id/subject_id — scope is key-derived server-side.
            "type": "command",
            "command": "loopctl-promote-session-hook"
          }
        ]
      }
    ]
  }
}
```

Idempotency makes the hook safe to fire on every Stop: an unchanged session is a
watermark skip (no LLM), and a re-fire adds no net rows. Over-budget fires are 429s
with no spend. The consumer uses the *shared*, key-derived scope; it never supplies a
`subject_id`.

## Seams (consumers)

- **Skills consumer — `mkreyman/claude-config#85`**. The Claude Code skills layer
  calls the `memory_*` MCP tools: `memory_remember` to persist what an agent learns
  mid-task, `memory_recall` to prime context at task start, `memory_list` to review
  a subject's memories, `memory_forget` to prune, and `memory_promote` (via the Stop
  hook above) to compile a finished session. It uses the *shared*, key-derived scope —
  it never supplies a `subject_id`. **Not implemented here**: loopctl ships the tools
  and endpoints; the hook + skills wiring live in claude-config#85.

Neither promotion nor the skills consumer changes the isolation model: promoted
memories and skills-written memories are owned by the same `(tenant, subject_id)`
boundary as any explicit write.

> **Doc reconciliation (#308):** the retired `docs/cole-medin-self-evolving-wiki.md`
> note was removed in PR #310; its durable content now lives in the KB hub
> (`fb9abd73`) and in this document — no parallel promotion doc exists (single-home).

---

## Verification (US-28.5, terminal)

- **End-to-end** (`Loopctl.Memory.E2ETest`): a memory written via the API is
  recalled identically via BOTH the context and the API.
- **Cross-surface isolation** (`Loopctl.Memory.CrossSurfaceIsolationTest`): a
  `(tenant T, subject A)` memory is invisible + immutable cross-tenant AND
  cross-subject on the context and API, on both the semantic and fallback paths,
  with no existence leak — plus MCP-layer scope-blindness in
  `mcp-server/test/memory_tools.test.js`.
- **Scale** (`Loopctl.Memory.ScaleRecallTest`, `@tag :scale`): a needle subject
  recalls its own top-k among an ~80k multi-subject corpus (run via
  `SCALE_TESTS=true mix test --only scale`).

## Verification (US-29.6, promotion terminal)

- **Promotion e2e** (`Loopctl.Memory.PromotionE2ETest`): a session promoted via
  `POST /api/v1/memory/promote` is recall-able through BOTH the context and the API,
  carrying `source: :promoted`, `source_session_id`, and a real `confidence`.
- **Idempotency + cross-scope** (`Loopctl.Memory.PromotionIsolationTest`): re-running
  promotion for an unchanged session (explicit trigger AND scheduled sweep) adds NO net
  rows measured **including superseded** (watermark skip); the promoted `(tenant T,
  subject A)` memory is invisible to tenant U AND to subject B via context, API
  (recall / index `?source=promoted` / forget), with MCP scope-blindness proven in
  `mcp-server/test/memory_tools.test.js` (US-29.4 AC-29.4.5).
- **Unattended safety** (`Loopctl.Memory.PromotionSafetyTest`): an injected
  "link this foreign article" instruction produces no cross-tenant-linked memory
  (`cross_links` stripped); an over-budget tenant's promote returns 429 with no LLM
  call; a compile failure emits `:failed` telemetry so a failing sweep is observable.
- **Promotion-quality eval** (`Loopctl.Memory.PromotionEvalTest`, US-29.5): the
  compiler's precision/recall against the committed labeled dataset — calibration only,
  never gates promotion.
