# Epic 42 — Recorded Structure

**Status: BOTH STORIES IMPLEMENTED.** US-42.2 merged in #718. US-42.1's harvester is built and tested; nothing schedules it yet, which is a deliberate separate decision recorded in that story. Per-story state and its merge PR live in the Stories table
below — that table is the single source of truth for what is done, and this header is
the only place that summarises it. Prose below is the epic's DESIGN record, written
against master 2026-08-20; read its present tense as "at design time".

## Thesis

Both stories replace an **inference** with a **record of something the system already
knows**.

The knowledge graph infers relationships from cosine similarity while exact provenance
sits unused in the `source_type`/`source_id` columns. The import path infers that a
story is well-formed while no artifact anywhere declares what a story is. In each case
the system is spending compute — or trust — to guess at a fact it is already holding.

The measurements that motivated this, both taken 2026-08-20:

| | |
|---|---|
| `relates_to` edges in the hosted corpus (#611) | 1,402,699 |
| of those, structural or hand-made | **0** |
| `derived_from` — a declared type with no producer in `lib/` | **0 edges** |
| distinct `book-` sources (`knowledge_facets`) | **210** |
| largest single book source | **1,523 articles** |
| committed epic folders of `us_N.M.json` | **39** |
| schemas declaring what a story is | **0** |
| stories that import cleanly with zero acceptance criteria | **all of them** |

## Why a star and not a clique (US-42.1)

The obvious harvest — link every article to its siblings — is catastrophic at this
corpus's shape. One 1,523-article book yields ~1.16M sibling edges on its own, more
than the entire pre-pruning graph #611 stage 0 was filed to reduce. Routing siblings
through one hub costs N edges instead of N²/2, keeps two-hop reachability meaningful,
and produces a node that has a *name* an agent can read.

This is stage 0.5 of #611: after the shipped prune (stage 0), before the LLM relation
typing (stage 1). It is deliberately cheap — no model call, no embedding, no judgment —
and it gives stage 1 a set of known-true edges to calibrate against.

## Why the schema is a declaration, not a dependency (US-42.2)

`validate_acceptance_criteria/2` prints an error asserting that criteria "must be an
array of objects with 'id' and 'description' keys" and then accepts `nil`, accepts
`[]`, and checks only `is_map/1`. The message states a contract the code does not hold.

The fix is one declared schema with two consumers — the generator emits against it, the
importer validates against it — bound together by a drift test rather than by a JSON
Schema runtime in the request path. The reason this matters beyond tidiness: acceptance
criteria are what `verify_story` is judged against, so an AC-less story can traverse the
entire custody chain to `verified` with nothing that could have been verified.

## What this epic deliberately does not do

- **No co-membership edges.** A shared `project_id` or a shared topical tag is a set
  membership, not a relation; harvesting those reintroduces the clique problem the star
  shape exists to avoid.
- **No LLM relation typing.** That is #611 stage 1 and is gated on stage 0's measurement.
- **No retrieval-quality ratchet.** Already shipped — `mix loopctl.retrieval.eval
  --fail-on-regression` compares against a committed baseline with a tolerance, and the
  baseline moves only through a reviewed diff.

## Stories

| Story | Title | Status | PR |
|-------|-------|--------|----|
| US-42.1 | Per-source hub articles and `derived_from` star edges | **implemented** — scheduling deliberately separate, see its technical notes | — |
| US-42.2 | A declared schema for work-breakdown imports, enforced instead of described | **merged-pending** | #718 |

Neither story depends on the other; they can land in either order.

## Breadcrumbs

- GH #611 — the graph diagnosis and the three stages
- `lib/loopctl/knowledge/link_pruning.ex` — stage 0, shipped
- `lib/loopctl/import_export.ex:868-885` — the validator this epic corrects
- `docs/research/autonomous-corpus-consolidation.md` — prior art for the consolidation work
