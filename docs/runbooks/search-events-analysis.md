# Runbook — monthly `search_events` review

`search_events` records one row per SEARCH ATTEMPT, including the ones that returned
nothing, degraded to keyword-only, or were rejected before they ran (#658). It exists
because the two failure modes that matter most were invisible in `article_access_events`,
which only records surfaced results.

A capture surface nobody reads is a capture surface that gets deleted. This is the
procedure, monthly, ~15 minutes.

## 0. Enrich first, on the machine that did the searching

Three columns cannot be filled by the client and are wrong or null until this runs:

- `client_model` — no model variable exists in the MCP server's environment.
- `client_effort` — likewise absent from that process (`CLAUDE_EFFORT` is set for Bash-tool
  invocations, not for the MCP server), so the column is NULL until enriched.
- `client_kind` — the client reports the SESSION's kind, not the caller's. One MCP process
  serves a session and every agent it dispatches, so it labels every search `main`. **An
  un-enriched `client_kind` is not caller-level truth** — do not compute a per-kind rate
  from one.

```bash
# on each dev machine that runs agents (transcripts never leave the machine)
mix loopctl.enrich_search_events --dry-run          # see what would change
mix loopctl.enrich_search_events --since-days 45    # then write
```

It joins on `(client_session_id, query)`, because a subagent's transcript records its
PARENT's session id — see `Loopctl.Knowledge.SearchEventEnrichment` for why the pair is
the only unambiguous key, and why a key two transcripts disagree about is dropped rather
than guessed.

A **resumed** session breaks that key: the restarted MCP server reports a fresh session id
while the transcript keeps appending under the original, so the pair can never match. The
task falls back to the query alone for those rows, and only for a query that is unambiguous
across the whole transcript tree (measured: 96% of distinct queries are). `client_model` and
`client_effort` are filled, never overwritten; `client_kind` IS corrected, because the value
the client sent is a session-level assertion rather than an observation. Re-running is safe
and idempotent either way.

## 1. Run the canonical queries

They live in the `Loopctl.Knowledge.SearchEvent` moduledoc, beside the schema they read,
and are deliberately NOT duplicated here — one copy cannot go stale against the other.
Open that file and run them against prod (`docs/runbooks/` has the connection recipe under
the fly-mpg notes, or use the `fly-mpg-connect` skill).

Add this one once the enrichment above has run — it is the whole point of the split:

```sql
-- Failure rate by agent kind and model. The baseline measured from transcripts was
-- main 8.2% / workflow 6.0% / subagent 3.7%; `child` averages that spread away.
SELECT client_kind, client_model, count(*),
       round(100.0 * count(*) FILTER (WHERE outcome IN ('zero_results','rejected'))
             / count(*), 1) AS bad_pct
  FROM search_events
 WHERE tenant_id = $1 AND inserted_at > now() - interval '30 days'
 GROUP BY 1, 2 ORDER BY 3 DESC;
```

## 2. Segment by origin BEFORE concluding anything

Server-side search traffic is roughly 4x transcript traffic and is dominated by
automation — one measured month carried `elixir` x2,056 as a query, 722
notification-derived hook queries, and 512 harvest dedup probes. A utilization metric
computed over that mix measures automation, not agents.

Split on `tool`, `client_entrypoint` and `client_kind` first. If a number moved, establish
which segment moved before attributing it to anything.

**The single most important filter is `client_host IS NOT NULL`.** A row without it never
passed through the MCP client at all, so it cannot be an agent's search: the UserPromptSubmit
recall hook and `scripts/smoke.sh` call the API directly. In the first 11 hours after this
table went live, 131 of 133 rows were exactly that — repeated `elixir` probes from the smoke
check and keyword-stripped `memory_recall` calls from the recall hook. Any rate computed over
the unfiltered table measures this project's own automation.

One operational trap belongs here too: **a long-running session keeps the mcp-server build it
booted with.** `npx` updating the cache does not restart it, so after publishing a version
that changes what the client sends, sessions started before the publish keep sending the old
payload until they are restarted. If context columns are unexpectedly sparse, check
`client_version` before suspecting the server.

## 3. What to look at, in order

| Signal | Healthy as last measured | What a regression means |
|---|---|---|
| zero-result rate on the default `combined` path | 0.7–0.9% | corpus gap, or a query-shape change — check the query-shape query before blaming the corpus |
| `degraded` rows by `fallback_reason` | near zero | an embedding provider problem, NOT a retrieval one. `no_embedding_key` means a tenant never provisioned one |
| `rejected` rows by `rejection_reason` | near zero | a client is sending something the API refuses — that is a tool-surface defect, and historically the largest single class |
| search→open follow-through | 1–7%, flat | the biggest number in this area and the least moved by anything shipped so far. See #652's closing section |

## 4. The trap

Search returns; agents do not open. Search-to-read has sat near 27:1, and 1.74% of
published articles have ever been opened. That is a harness/consumption problem, not a
search or corpus one — fixing retrieval further will not move it. Do not spend a month's
work on the retrieval side on the strength of a utilization number that was never
segmented by origin (step 2).
