---
name: oban-health
description: Use when checking whether loopctl's background jobs are actually running and healthy in production — a routine "is everything in order" sweep, an investigation into a worker that seems stuck, or triage of a queue backlog. Covers the state/queue sweep, cron-coverage verification, and the three readings that a naive look gets WRONG (snoozes read as retries, parked crons read as broken, zero-count queues read as healthy). Triggers on: oban health, are jobs running, background jobs, job queue backlog, stuck job, oban_jobs, cron not firing, worker not running, queue starved, orphaned executing, discarded jobs, job failures, oban check.
---

# Oban Health Check (production)

The sweep below answers "are the background jobs in order?" in about six queries. It exists
because three of the readings are traps: the raw numbers look like incidents when they are
correct behaviour, and look correct when they hide a dead producer.

## Connect

Production Postgres is the unmanaged `ecf-postgres` instance (see the `fly-mpg-connect` skill —
`fly mpg` cannot see it).

```bash
# proxy (skip if 127.0.0.1:15432 is already listening — check with: ss -ltn | grep 15432)
flyctl proxy 15432:5432 -a ecf-postgres &

set -a && . ~/.ecf_postgres_env && set +a
export PGPASSWORD="$LOOPCTL_DB_PW"
psql -h 127.0.0.1 -p 15432 -U loopctl -d loopctl -X   # -X: skip ~/.psqlrc
```

`Oban.Plugins.Pruner` deletes terminal jobs older than **7 days**, so every count below is a
rolling 7-day window. Absence of an old job is pruning, not a failure.

## The sweep

```sql
-- 1. state x queue: the headline. Anything not 'completed' is worth a look.
select queue, state, count(*) from oban_jobs group by 1,2 order by 1,2;

-- 2. orphans: jobs wedged in :executing past Lifeline's 30-min rescue window
select worker, queue, attempt, attempted_at, now()-attempted_at as age
from oban_jobs where state='executing' order by attempted_at;

-- 3. real failures. `errors` is jsonb[] — use errors[1], NOT errors->0 (that raises).
select count(*) from oban_jobs where cardinality(errors) > 0;

-- 4. per-worker cadence: the core table. Compare runs_24h against the crontab.
select replace(worker,'Loopctl.Workers.','') as worker, queue,
       count(*) as runs_7d,
       count(*) filter (where inserted_at > now()-interval '24 hours') as runs_24h,
       max(completed_at)::timestamp(0) as last_run,
       round(extract(epoch from now()-max(completed_at))/60)::int as mins_ago,
       round(avg(extract(epoch from (completed_at-attempted_at)))::numeric,2) as avg_secs
from oban_jobs group by 1,2 order by 6;

-- 5. cron GAPS (the real liveness test — a per-minute worker must never gap)
with t as (select inserted_at, lag(inserted_at) over (order by inserted_at) prev
           from oban_jobs where worker='Loopctl.Workers.SystemConfigRefreshWorker')
select prev::timestamp(0) gap_start, inserted_at::timestamp(0) gap_end,
       round(extract(epoch from inserted_at-prev)/60)::int gap_mins
from t where inserted_at - prev > interval '3 minutes' order by 1;

-- 6. leader + table size
select * from oban_peers;
select pg_size_pretty(pg_total_relation_size('oban_jobs')), count(*) from oban_jobs;
```

Then the app's own verdict, which is cheaper than all of the above when it is green:

```bash
fly checks list -a loopctl
# healthy output: {"status":"ok","ready":true,
#   "checks":{"oban":"ok","database":"ok","oban_orphans":"ok","scale_alerts":"ok"}}
```

## Expected cadence

`Loopctl.ObanConfig.plugins/0` (`lib/loopctl/oban_config.ex`) is the source of truth for the
crontab — read it rather than trusting a list here, which rots. Derive expected `runs_24h`
from the schedule: `* * * * *` → 1440, `*/5` → 288, `*/10` → 144, hourly → 24, daily → 1.

Two adjustments before you call a count wrong:

- **`mode: "all_tenants"` workers fan out**, so `runs_24h` is `ticks x (1 + tenants)`, not
  `ticks`. `ComputeSthWorker`, `KnowledgeLintWorker`, `KnowledgeMocWorker`,
  `RetrievalMetricsWorker`, `EmbeddingReconciliationWorker` all do this.
- **`CostAnomalyWorker` is not in the crontab.** It is chained by `CostRollupWorker` after the
  daily rollup (`lib/loopctl/workers/cost_rollup_worker.ex:12`), which is why it shows up
  ~5 min after the 02:00 rollup with no schedule of its own.

## The three traps

### 1. `attempt > 1` with an empty `errors` array is a SNOOZE, not a retry

Oban's `snooze_job/3` does `inc: [max_attempts: 1]` — it raises the ceiling as it defers. So a
snoozed job shows a climbing `attempt`, a `max_attempts` climbing in lockstep, and **no recorded
error**. Distinguish them:

```sql
select replace(worker,'Loopctl.Workers.','') w, attempt, max_attempts,
       cardinality(errors) n_errors, state, count(*)
from oban_jobs where attempt>1 group by 1,2,3,4,5 order by 6 desc;
```

`n_errors = 0` and `max_attempts = attempt + N` ⇒ snooze. In loopctl these come from the US-36.2
per-tenant fair-share gate (`Loopctl.Oban.FairShare`) on `ArticleLinkingWorker` /
`ArticleEmbeddingWorker`, and they cluster at **04:00–05:00 UTC** where the daily `KnowledgeLint`
(04:00), `RetrievalMetrics` (04:30) and weekly `KnowledgeMoc` (05:00) all-tenant fan-outs occupy
the `:knowledge` lane. That is the gate working.

**But verify they cleared** — do not stop at "it's a snooze". A snooze is unbounded by
construction and cannot exhaust into `discarded`, so a job gated on a permanently-wrong condition
stalls forever while nothing fails and nothing alerts:

```sql
select state, count(*) from oban_jobs where attempt>1 group by 1;   -- want: completed only
```

loopctl is structurally protected here because the fair-share cap has a **floor of 1** (see the
"always >= 1 slot" invariant in `oban_config.ex`), so the gate can never wedge a queue with every
job snoozing. Do not remove that floor. Wiki: *"Oban's snooze raises max_attempts, so a job gated
on a permanently-wrong health check stalls forever and never fails"*.

### 2. Five workers are PARKED on purpose — silence is correct

`ObanConfig.parked_crons/0` keeps `MemoryPromotionSweepWorker`, `MemoryGraduationSweepWorker`,
`SessionMemoryPruneWorker`, `PromotionEvalWorker` and `IngestionHealthWorker` dormant by default
(#249, 2026-08-11). Their code is intact; only the schedule is off. They earned it by running
green and doing nothing — the audit's "level 1" failure, which no success rate surfaces.

A `last_run` frozen at **2026-08-11** for exactly these five is the parking, not an outage.
Confirm rather than assume, with two checks:

```bash
fly secrets list -a loopctl | grep -i OBAN_UNPARK_CRONS    # no row ⇒ still parked
```
```sql
select (select count(*) from memories) m, (select count(*) from session_memories) sm;
```

If `m`/`sm` are still 0, the parking rationale still holds — nothing calls `memory_remember`, so
the memory sweeps would sweep an empty tier. **If they are non-zero, the parking is now wrong**
and the memory sweeps should be revived with
`fly secrets set OBAN_UNPARK_CRONS=Loopctl.Workers.MemoryPromotionSweepWorker,... && fly apps restart loopctl`
(no deploy needed). Graduation is demand-gated, which is exactly the writer worth reviving.

### 3. A zero-count queue proves nothing until you check its PRODUCER

This is the trap that makes a health check worthless. `webhooks`, `ingestion` and `verification`
routinely show **zero jobs in 7 days**. Zero is what a healthy quiet week looks like *and* what a
dead producer looks like. Resolve it by counting the rows that would have enqueued the job:

```sql
select 'webhooks' t, count(*) n from webhooks                 -- 0 subs  ⇒ 0 deliveries is CORRECT
union all select 'webhook_events', count(*) from webhook_events
union all select 'verification_runs', count(*) from verification_runs  -- L3 unused in prod
union all select 'articles_7d', count(*) from articles
         where inserted_at > now()-interval '7 days';         -- ingestion path is alive?
```

Knowledge writes reach loopctl through the **direct `knowledge_create` path**, not the batch
`ContentIngestionWorker` lane, so an idle `:ingestion` queue alongside a healthy `articles_7d`
count is normal. Split it by writer:

```sql
select coalesce(source_type,'(direct)') st, count(*) from articles
where inserted_at > now()-interval '7 days' group by 1 order by 2 desc;
```

The rule, from the wiki: **a stall must be as visible as a crash.** If the only observable
difference between "quiet day" and "totally broken" is a number that is zero either way, you have
no monitoring — go count the producer.

## Bonus check: the embedding blackout

Not an Oban table, but it is what the hourly `EmbeddingReconciliationWorker` exists to prevent,
and a gap here is a silent recall blackout that no job failure reports:

```sql
select count(*) as published_without_embedding from articles a
where a.status='published'
  and not exists (select 1 from article_embeddings e where e.article_id=a.id);
```

Want 0. Non-zero means the reconciliation sweep is falling behind — check its `runs_24h` (expect
24 x fan-out) before assuming an embedding-provider outage.

## Reading the Fly side

- `fly status -a loopctl` showing one machine `suspended` with a `warning` check whose output is
  "the machine hasn't started" is the **autostop standby**, not a failure. Judge the `started` one.
- `oban_peers` should hold one live leader with `expires_at` in the near future; `started_at` is
  effectively node uptime.
- Cross-check that the deployed release actually contains the crontab you just read:
  `fly releases -a loopctl | head -3` against `git log --first-parent -1 --date=iso`.
