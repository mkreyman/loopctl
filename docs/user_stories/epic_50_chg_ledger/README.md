# Epic 50 — chg change ledger and dashboard in loopctl

Source: mkreyman/loopctl#1014. Mark, 2026-10-28: *"I insist on extending loopctl for that and
NOT building a separate app."* There is no chg-server. loopctl holds chg's ledger, its change
events and a dashboard; every fleet machine sends through a local outbox, so loopctl is never
on chg's push or merge path and an outage costs only freshness.

## What changes against Epic 47

Epic 47 assumed one chg-server that loopctl could call. Two things in it have no caller now.

1. **The gap pull.** `Loopctl.Changes.ChgClient` pulls `GET /api/v1/changes/:id/events?after=N`
   from chg-server. Per-machine outboxes are not reachable from loopctl, so the pull is
   replaced by a sender-driven fill (US-50.2): every answer to an event post carries the
   change's cursor (`applied_through`, the held seqs), and the sender resends from it. A gap or
   a stale change that no sender fills raises an operator alert and shows on the dashboard.
   `ChgClient`, `ReqChgClient` and `CHG_SERVER_URL` are deleted.
2. **The chg root's key holder.** Epic 47 §6 had chg-server hold a key of the
   `chg_root_dispatch_id` root and mint one child per review. A dispatch key lives at most
   14400 s (`Dispatches`, `@max_expires_seconds`), and the operator key cannot mint under a
   root it is not in the lineage of, so no fleet process can hold a standing root key.
   US-50.3 lets the enrolled `:chg` source mint the review child server-side, authenticated by
   the source's `change_events_secret` (the same credential that already moves its stages).
   The root stays a lineage anchor: a row, never a held key.

## Wire contract the fleet sender codes against

All machine endpoints are HMAC-signed exactly as US-47.3: `X-Chg-Timestamp`,
`X-Chg-Signature: sha256=<hex>` over `"<timestamp>.<raw body>"` (POST) or
`"<timestamp>.GET.<path>?<query>"` (GET), keyed by the source's `change_events_secret`,
5-minute window, one identical 401 for every refusal.

| endpoint | story | purpose |
|---|---|---|
| `POST /api/v1/change_events/:source_id` | 47.3, 50.2 | one change event; the answer now carries the change's cursor |
| `GET /api/v1/change_events/:source_id/cursor?change_id=` | 50.2 | the cursor alone, for a sender that restarted |
| `POST /api/v1/chg_ledger/:source_id` | 50.1 | a batch of ledger rows (shadow `chg`/`gate` rows, review rounds, flaky tests, runner samples) |
| `POST /api/v1/change_events/:source_id/review_dispatch` | 50.3 | mint the review child for `(change_id, revision)` |

The sequencer requirement stays chg's: `event_seq` is per change, from 1, with no gaps, even
when a change's events originate on different machines. loopctl holds events ahead of a gap
until a sender fills it and never invents a seq.

## Stories

| story | what | depends on |
|---|---|---|
| 50.1 | Ledger rows: table and batch ingest | — |
| 50.2 | Sender-driven gap fill; delete the chg-server pull | — |
| 50.3 | Source-minted review dispatches under the chg root | — |
| 50.4 | Review outcomes from merged PR bodies | 50.1 |
| 50.5 | Operator browser login and the chg dashboard | 50.1, 50.2, 50.4 |
| 50.6 | Read API and MCP tool for the ledger summary | 50.1, 50.4 |

The chg side (design §5/§10 rewrite, chg#33, the Rust outbox and sender, `chg doctor` depth,
the shadow backfill sender, calling 50.3) is handed off on the chg channel, ref
`handoff:chg:loopctl-ledger-sender`. US-47.8, the pilot, stays in Epic 47 and runs once the
sender delivers real events.

## Decisions Mark may overrule

| default | where | effect of overruling |
|---|---|---|
| The fleet sender holds `change_events_secret`, so any fleet machine can mint a review child (50.3) | US-50.3 | the alternative is a standing reviewer host with its own secret; it narrows who can mint reviewers to one machine and makes that machine a single point of failure for review |
| A `review_round` ledger row names its pull request in `"pr"` (a positive integer); rounds are counted on `raw->>'pr'` (50.4) | US-50.4 | the stories named no key; the alternative is matching on the merge sha, which a review of an earlier head does not carry |
| A gap no sender fills alerts the operator; loopctl never pulls | US-50.2 | a pull needs a reachable chg endpoint, which is the chg-server Mark ruled out |
| Ledger rows are kept 180 days, then deleted by a nightly prune | US-50.1 | longer retention grows the table without bound; the audit questions look back weeks |
