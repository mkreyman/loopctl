defmodule Loopctl.RateLimiter.Postgres do
  @moduledoc """
  CLUSTER-GLOBAL rate limiter implementation backed by a shared Postgres
  windowed-counter table (US-38.2, Epic 38, GH #353).

  ## Why this exists

  The default limiter (`Loopctl.RateLimiter.Hammer`, ETS) is per-NODE, so any
  configured limit becomes `limit × N` across an N-node cluster — defeating the
  DB-pool and provider-429 protection it exists for. This implementation shares
  ONE counter store across every node via Postgres (already in-stack; no Redis),
  so a limit configured today means the same thing on 1 node or 10.

  It is selected via config-based DI (`:rate_limiter`); when UNSELECTED — the
  DEFAULT — this module is never invoked and the limiter is the node-local ETS
  `Loopctl.RateLimiter.Hammer`. Single-node results are OBSERVABLY IDENTICAL
  across the two (both are fixed-60s-window `count <= limit` counters aligned to
  unix-minute boundaries); it is a different in-memory store, not literally the
  same bytes, so the guarantee is behavioural parity, not a byte-for-byte store.
  Every behaviour-based caller (the web RPM plug, `Loopctl.Provider.Admission`,
  the signup/enroll/retrieve rate gates) becomes cluster-global with NO call-site
  change the moment the Postgres impl is selected — they all resolve the active
  impl via `Loopctl.RateLimiter.impl/0` and call `check_rate/3`.

  ## Algorithm — atomic FIXED-WINDOW counter (no read-modify-write race)

  Each check performs ONE atomic statement against a small counter table:

      INSERT INTO rate_limit_counters (..., count, ...) VALUES (..., 1, ...)
      ON CONFLICT (bucket, window_start)
      DO UPDATE SET count = rate_limit_counters.count + 1
      RETURNING count

  Because the increment-and-return happens inside a single `INSERT ... ON
  CONFLICT ... DO UPDATE ... RETURNING`, two concurrent nodes racing the same
  bucket can never both read a stale count and exceed the limit — Postgres
  serializes the row update and each caller sees its own post-increment count.
  The returned count drives the decision: `count <= limit -> {:allow, count}`,
  else `{:deny, limit}`. This matches the Hammer fixed-window contract closely
  (see `Loopctl.Provider.Admission`'s window-semantics note): a fresh window
  opens on the first request for a `(bucket, window)` and resets at the boundary.

  ## Bounded cost — and its contention/bloat hotspot

  Exactly one indexed row touch per check (the `(bucket, window_start)` unique
  index is both the ON CONFLICT target and the point lookup) — never a scan, no
  N+1. Old windows are pruned cheaply by
  `Loopctl.Workers.RateLimitCounterCleanupWorker` (a bounded index-range delete
  on `window_start`), not on the hot path.

  This is NOT free at scale, and the design (AC-prescribed) can't avoid it:

    * **Single-row serialization.** Every check — INCLUDING already-over-limit
      requests — issues `DO UPDATE SET count = count + 1` against the ONE
      `(bucket, window_start)` row for that bucket's current window. For the
      hottest tenant under overload (exactly the scenario `RATE_LIMITER=postgres`
      targets) this converts a lock-free per-node ETS `update_counter` into a
      network round-trip plus a contended single-row `UPDATE`: every node
      serializes on that row's lock. The obvious `WHERE count < limit` guard
      CANNOT be used — a non-matching WHERE returns no row, `%{rows: [[count]]}`
      fails to match, and the rescue fails OPEN (disabling the limit), so the
      increment must run on every request.
    * **Dead-tuple bloat.** Each increment produces a dead tuple, so the hot
      row bloats within its 60s window until autovacuum catches up.

  Before enabling at scale, consider aggressive per-table autovacuum settings on
  `rate_limit_counters` and monitor lock waits / row bloat on the hottest buckets.

  ## Access path — `Loopctl.AdminRepo`, cross-tenant, ON THE REQUEST HOT PATH

  `rate_limit_counters` is a GLOBAL table with NO `tenant_id`; tenant/key
  isolation lives entirely in the `bucket` STRING (`"key:<uuid>"`,
  `"tenant:<uuid>"`, `"provider_admission:embedding:<uuid>"`, ...). The limiter
  runs CROSS-TENANT (one shared store), so — exactly like `system_configs` — it
  is accessed via `Loopctl.AdminRepo` (BYPASSRLS in prod, table owner in
  dev/test), NEVER `Loopctl.Repo` (whose RLS would block cross-tenant writes).
  RLS is ENABLEd on the table only to deny that low-privilege role.

  This DELIBERATELY broadens where the BYPASSRLS `AdminRepo` connection runs:
  when this impl is selected, `check_rate/3` issues an `AdminRepo.query!` on the
  hot path of EVERY authenticated API request and every outbound provider check —
  wider than `AdminRepo`'s historical "never for regular tenant-scoped requests"
  scope (see `Loopctl.AdminRepo`). It is safe on the merits: the table holds no
  tenant data and the statement is a fixed, fully parameterized single upsert, so
  BYPASSRLS confers no extra leak/injection risk. But two operational
  consequences must be planned for before a clustered rollout:

    1. Every check consumes an `AdminRepo` pool connection, so under load/attack
       the limiter can EXHAUST the `AdminRepo` pool → raise → the fail-open path
       below → self-reinforcing loss of rate limiting under exactly the load the
       limiter exists to contain. Size and monitor the `AdminRepo` pool for this
       per-request load before enabling.
    2. The `AdminRepo` contract is now broader than its original docs — future
       changes must not assume `AdminRepo` is off the request path.

  ## Fail-OPEN (parity with the ETS/Hammer path and US-37.1)

  A monitoring/limiter fault must NEVER block all traffic. ANY error raised,
  exited, or thrown by the DB call is caught, LOGGED (throttled + PII-safe, see
  `fail_open/2`), and returns `{:allow, 0}` (allow the request, full remaining) —
  the limiter degrades to "no gate", never to "deny everything". `{:allow, 0}`
  (not `{:error, _}`) is returned deliberately so callers that only branch on
  `{:allow, _}` / `{:deny, _}` (the web plug) stay robust without a call-site
  change.

  Selecting this impl broadens fail-open to EVERY caller resolving through
  `Loopctl.RateLimiter.impl/0`. To keep it from silently unlocking the
  anti-abuse / brute-force SECURITY gates (signup abuse, WebAuthn-verify,
  enroll), those gates call `Loopctl.RateLimiter.gate_ok?/3`, which treats the
  `{:allow, 0}` fail-open sentinel as DENIED (fail-CLOSED). The capacity gates
  (RPM plug, retrieve, provider admission) intentionally stay fail-OPEN. This
  tradeoff is also documented at the `RATE_LIMITER=postgres` switch in
  `config/runtime.exs`.
  """

  @behaviour Loopctl.RateLimiter.Behaviour

  alias Loopctl.AdminRepo
  alias Loopctl.RateLimiter.FailOpenLog

  @upsert """
  INSERT INTO rate_limit_counters (id, bucket, window_start, count, inserted_at, updated_at)
  VALUES (gen_random_uuid(), $1, $2, 1, (now() AT TIME ZONE 'UTC'), (now() AT TIME ZONE 'UTC'))
  ON CONFLICT (bucket, window_start)
  DO UPDATE SET count = rate_limit_counters.count + 1, updated_at = (now() AT TIME ZONE 'UTC')
  RETURNING count
  """

  @impl true
  @spec check_rate(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def check_rate(bucket, window_ms, limit)
      when is_binary(bucket) and is_integer(window_ms) and is_integer(limit) do
    # Align the window to the wall clock so every node buckets an event to the
    # SAME window_start (cluster-global correctness) and windows reset on shared
    # boundaries — the same fixed-window shape Hammer uses. The clock is resolved
    # via config-based DI (`:clock`, default `Loopctl.Clock.Default`) so a test
    # can pin/advance the wall clock and assert window rollover deterministically.
    window_start = div(now_ms(), window_ms) * window_ms

    %{rows: [[count]]} = AdminRepo.query!(@upsert, [bucket, window_start])

    if count <= limit, do: {:allow, count}, else: {:deny, limit}
  rescue
    e -> fail_open(bucket, Exception.message(e))
  catch
    :exit, reason -> fail_open(bucket, "exit: #{inspect(reason)}")
    :throw, value -> fail_open(bucket, "throw: #{inspect(value)}")
  end

  # Fail OPEN on ANY limiter/DB fault: log and allow. Single sink so every
  # failure mode degrades identically (parity with Loopctl.Provider.Admission).
  # The warning is emitted through the THROTTLED, PII-safe
  # `Loopctl.RateLimiter.FailOpenLog` (at most one line per bucket-family per
  # window, IP/UUID suffix stripped) so a sustained DB outage — when EVERY check
  # fails here — cannot flood the logs or write client IPs into them.
  #
  # NOTE: `{:allow, 0}` is the fail-open SENTINEL. Capacity callers
  # (`within_limit?/3`, the RPM plug) honour it as "allowed"; the anti-abuse /
  # brute-force security gates use `Loopctl.RateLimiter.gate_ok?/3`, which treats
  # `{:allow, 0}` as DENIED — so selecting this impl does NOT broaden fail-open
  # into those security gates.
  defp fail_open(bucket, detail) do
    FailOpenLog.warn(:postgres, bucket, detail)

    {:allow, 0}
  end

  # Current wall-clock milliseconds via the DI-injected clock (default real
  # system time). Mirrors the injectable clock the other windowed limiters use so
  # window boundaries are deterministically testable.
  defp now_ms, do: DateTime.to_unix(clock().utc_now(), :millisecond)

  defp clock, do: Application.get_env(:loopctl, :clock, Loopctl.Clock.Default)
end
