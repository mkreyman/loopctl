# Epic 43 — Corpus Tier

**Status: DESIGNED, NOT IMPLEMENTED.** Per-story state and its merge PR live in the
Stories table below — that table is the single source of truth for what is done, and
this header is the only place that summarises it. Prose below is the epic's DESIGN
record, written against master `0a6b48f` on 2026-08-27; read its present tense as
"at design time".

Origin: GH #770, handed off from a mac-mini session. First consumer:
mkreyman/home_care_billing#1385.

## Thesis

An agent should have **one** search surface. Today a repo with a reference-document
corpus needs a second, per-machine RAG stack beside loopctl. This epic lets loopctl
**host the index while the physical files stay in their own repo**: retrieval returns
`{source_ref, locator, snippet, score}` and the agent opens the local file itself.

It is a third storage tier, not a fourth agent surface in the Epic 28/30 sense — it
sits beside the Knowledge Wiki with a different contract:

| | Knowledge Wiki (`knowledge_*`) | Corpus tier (`corpus_*`) |
|---|---|---|
| what is stored | DISTILLED articles, LLM-extracted | VERBATIM chunks, never paraphrased |
| what retrieval returns | the article body | a POINTER plus a snippet |
| where truth lives | in loopctl | in the file, on the agent's disk |
| the question it answers | "what did we learn about X" | "quote me loop 2310B" |

The distinction is not stylistic. A companion-guide summary is the one thing you
cannot cite back to a payer, so `knowledge_ingest` — which runs LLM extraction and
yields articles — is the wrong shape for this material even though it is the right
shape for the lesson learned from reading it.

## What already exists (verified against master, 2026-08-27)

The expensive parts are built. Every claim below was re-checked in the code, not
taken from the issue:

| claim | verified at |
|---|---|
| unconstrained `vector` column + `dim` discriminator + `vector_dims` CHECK | `lib/loopctl/knowledge/article_embedding.ex:41-47`, `priv/repo/migrations/20260721000100_create_embedding_side_tables.exs` |
| local Ollama-servable models already mapped (nomic 768, bge, mxbai, snowflake-arctic) | `lib/loopctl/embeddings/dimensions.ex:48-61` |
| 768 is in the SUPPORTED set, so mode B has a pre-built HNSW index path | `config/config.exs:38` (`[768, 1024, 1536]`) |
| semantic search is vector-in, not string-in | `lib/loopctl/knowledge.ex:8461` |
| per-dimension HNSW DDL is already single-sourced and reusable for a new table | `lib/loopctl/repo/hnsw_index.ex`, `priv/repo/migrations/20260721000200_*` |
| the conjunctive tenant predicate a BYPASSRLS read must satisfy | `lib/loopctl/heavy_read.ex` moduledoc |

## The design problem #770 did not name: where the dimension is pinned

`Loopctl.Embeddings.active_dimension/1` resolves a dimension **per TENANT**, and the
`20260721000300` migration pinned it deliberately so that the corpus's actual shape,
not a mutable model setting, is authoritative. Mode B breaks that assumption: a tenant
whose article corpus is pinned at 1536 will index a document corpus with a LOCAL
768-dimension model, and both must coexist.

So **a corpus carries its own `dim` and `embedding_model`, pinned at
`corpus_create` and immutable thereafter.** The tenant pin governs `articles` and
`memories` and is not consulted for a corpus. Re-dimensioning a corpus is exactly one
supported operation — delete it and re-index — because there is no distilled state to
preserve; the source files are the truth and re-indexing is cheap.

This is the single most consequential decision in the epic. Reading the tenant pin
here would make the first consumer unimplementable.

## Two modes, and the second is the point

**Mode A — server embeds.** The client sends chunk text; loopctl embeds with the
corpus's configured model. Both retrieval lanes work, keyword included. Right for
public reference material: HCPF companion guides, X12 Glass captures, published books.

**Mode B — client embeds; the server stores vectors it cannot read.** The client runs
a local model and sends `{source_ref, locator, vector, content_hash}`. `text` is NULL.
Semantic lane only.

Mode B is what makes this usable for a Medicaid repo, a client codebase, or anything
under NDA: the index is centralized and cross-machine, the content never leaves the
machine. It is also the answer to "why not just commit a FAISS index" — a committed
index still needs the query stack installed per machine, and still cannot be reached
by an agent on a box with no checkout.

**Mode B's privacy claim is scoped honestly, and the scoping is load-bearing.** A
mode-B chunk may carry an optional short `snippet`, and a snippet IS text the server
sees. So the claim is not "the server never sees any text" — it is "the server never
sees the full document, and the client chooses what, if anything, to expose." For a
PHI corpus the correct choice is no snippet at all, so **`snippet` defaults to NULL in
mode B** and a corpus may be created with snippets forbidden outright. A default that
quietly exposed 300 characters of every chunk would defeat the mode while appearing to
honour it.

## Why the corpus-pollution question needs no policy

The obvious objection is that verbatim spec chunks would flood tenant-wide recall
injection — `hooks/kb-recall-on-prompt.sh` in claude-config deliberately skips the
`project_id` resolve to save a round trip, so anything in the article corpus is a
recall candidate in every repo.

`/api/v1/recall`, `knowledge_heat_index`, novelty scoring and the consolidation pass
all query `Loopctl.Knowledge.Article`. A separate table is excluded from every one of
them **by construction** — no exclusion flags, no policy, nothing a later change can
forget. That is a positive argument for a distinct tier rather than an article
subtype, and US-43.1 carries a guard test so the property is asserted rather than
assumed.

## Role gating

Applying the CLAUDE.md checklist rather than inheriting the KB's answers:

| operation | role | why |
|---|---|---|
| `corpus_create`, `corpus_index`, `corpus_list`, `corpus_status`, `corpus_search` | `:agent` | non-destructive + audited — the same criteria that earn the KB content carve-out its agent role |
| `corpus_delete` | `:user` | set-based blast radius AND irreversible: one call destroys every chunk and vector in a corpus, and nothing restores them |

`corpus_index` is a mutating write, but it is idempotent on `(corpus_id, source_ref,
locator, content_hash)` and destroys nothing, so it does not reach the `:user` line.
Re-indexing a changed document replaces only that document's chunks; there is no
set-based delete verb below `:user`.

## What this epic deliberately does not do

- **No chunking.** The client chunks and sends chunks. loopctl stores and ranks. The
  KB's own finding is that fixed-size splitting degrades retrieval and chunks must
  respect the source's semantic structure — that is a real problem and it is not this
  tier's. Keeping the chunker out means it can be replaced without touching storage.
- **No document fetching or parsing.** loopctl never opens a PDF.
- **No re-embedding of an existing corpus at a new dimension.** Delete and re-index.
- **No cross-corpus federated search in v1.** `corpus_search` takes a corpus id or a
  project scope; ranking across corpora with different models and dimensions is not a
  meaningful single ordering and pretending otherwise would produce confident nonsense.

## Relationship to ContextForge

The KB carries `ContextForge` as an idea-forge candidate — a document-ingestion
service producing typed, deduplicated chunks, "with loopctl as the first consumer".
These are complementary and the boundary is clean: **this epic is the storage and
retrieval tier; ContextForge is the chunking and typing quality layer that feeds it.**
Building this first gives ContextForge a real consumer to develop against.

## Stories

| Story | Title | Status | PR |
|-------|-------|--------|----|
| US-43.1 | Corpus storage: a corpus that pins its own dimension, and chunks excluded from the article corpus by construction | not started | — |
| US-43.2 | Mode A — server-embedded ingest and pointer-plus-snippet retrieval | not started | — |
| US-43.3 | Mode B — the server stores and ranks vectors it cannot read | not started | — |
| US-43.4 | The `corpus_*` tool surface, and a routing rule that says when to reach for it | not started | — |

Strictly sequential: each depends on its predecessor.

## Exit criterion, and the half that is not a loopctl story

The epic is not done when US-43.4 merges. It is done when an agent on any machine can
answer an X12 segment question against the real corpus. That cutover —
`home_care_billing` #1385: a committed indexer script, mode B with a local 768-dim
model, `local-faiss-mcp` removed from `.mcp.json`, three CLAUDE.md references
corrected — is a change to a DIFFERENT repo and is therefore not a story here. It
leaves this epic as a handoff on the `home_care_billing` coordination channel once
US-43.4 merges.

**Its corpus size is misstated in every source, so measure before sizing that work.**
#1385 says 1992 PDFs; the #770 handoff says 83 PDFs / 1363 pages; the checkout on
minis at `03d4771b` has 78 PDFs under `docs/`, 42 of them under `docs/hcpf-edi/`. The
order of magnitude (tens, not thousands) is what the design should assume.

## Breadcrumbs

- GH #770 — the original design, its five-step slicing, and the two modes
- GH mkreyman/home_care_billing#1385 — the first consumer and the measured state of what it replaces
- `priv/repo/migrations/20260721000100_create_embedding_side_tables.exs` — the pattern US-43.1 follows
- `lib/loopctl/heavy_read.ex` — the tenant-predicate contract every new heavy read must satisfy
- `docs/knowledge-hybrid-retrieval.md` — the retrieval shape `corpus_search` deliberately does NOT copy
