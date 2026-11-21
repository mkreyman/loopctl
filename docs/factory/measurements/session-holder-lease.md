# Session holder lease: the measurement (US-52.19)

PRD section 9 asked how long interactive sessions go between tool calls, because that decides
what renews a session holder's lease and how long a dead session may keep its claims. This
records one run of the measurement and the values it sets.

## The run

- **Date:** 2026-11-20.
- **Window:** transcripts modified in the last 30 days.
- **Hosts:** minis, x1, ryzen, beelink, nuc, mac-mini, blockit. Every host was reachable. nuc
  had no transcripts in the window. xps13 is retired and was not measured.
- **Input:** each host's `~/.claude/projects/**/*.jsonl`, minus `*/subagents/*` (a subagent's
  transcript carries its parent's `sessionId`, and its tool calls would fill the parent's idle
  gaps). The scratchpad extractor reduced each host's files on that host to one line per
  assistant entry holding a `tool_use`: `sessionId`, `timestamp` and the `tool_use` marker. No
  tool input and no text left the host.
- **Command:** `mix loopctl.session_gaps <one directory per host>`. 0 lines were skipped as
  malformed.

| Host | Sessions | Gaps | p50 (s) | p95 (s) | p99 (s) | Max (s) | > 300 s | > 3600 s |
|---|---|---|---|---|---|---|---|---|
| minis | 410 | 76140 | 3.3 | 72.2 | 547.2 | 826223.6 | 1383 | 48 |
| x1 | 328 | 76635 | 4.5 | 104.6 | 626.7 | 73360.6 | 1770 | 46 |
| ryzen | 336 | 62256 | 2.9 | 53.9 | 563.5 | 150367.5 | 1008 | 50 |
| beelink | 37 | 3353 | 4.0 | 120.5 | 994.6 | 50079.6 | 95 | 6 |
| nuc | 0 | 0 | — | — | — | — | 0 | 0 |
| mac-mini | 478 | 51916 | 4.2 | 141.5 | 1308.1 | 1640396.7 | 1765 | 136 |
| blockit | 917 | 106040 | 2.9 | 30.9 | 483.6 | 256805.3 | 1746 | 75 |

## What it says

On every host the p99 gap between one session's tool calls (484 s to 1,308 s) is longer than
a five-minute lease, and hundreds of gaps per host exceed an hour: sessions sit open and idle
while Mark is away, and some are resumed days later (the longest gap is 19 days). A lease
renewed by tool calls would release his items while he is gone.

So the rule applies: **renewal is driven by the MCP process's timer, not by tool calls,** and
the lease only bounds how long a DEAD process keeps its claims. The MCP server heartbeats
while its session is open, idle or not (US-52.13, `mcp-server/lib/holder.js`), and every
heartbeat moves the holder's uncapped claims to its new `lease_until` (US-52.19). The lease
is five heartbeat intervals, so four lost or delayed heartbeats in a row still keep the
claims.

## The values

HOLDER_HEARTBEAT_SECONDS: 60
HOLDER_LEASE_SECONDS: 300

These are `Loopctl.Holders.default_heartbeat_seconds/0` and `default_lease_seconds/0`;
`test/loopctl/holders_lease_measurement_test.exs` fails when they and these two lines differ,
or when the lease is not five heartbeats. A dead session's claims are released within one
lease plus one sweep of `Loopctl.Workers.ReclaimExpiredClaimsWorker` (every 5 minutes): ten
minutes at most.

## What would change them

- A slow-network case where a live session's heartbeats take longer than four intervals:
  raise the heartbeat interval and the lease together.
- Claims that must outlive a crashed session for longer than ten minutes: raise the lease,
  knowing a dead session then holds its items that long.

Re-run the measurement with the extractor and the mix task above before changing either.
