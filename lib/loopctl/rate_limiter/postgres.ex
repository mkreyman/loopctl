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

  ## Bounded cost

  Exactly one indexed row touch per check (the `(bucket, window_start)` unique
  index is both the ON CONFLICT target and the point lookup) — never a scan, no
  N+1. Old windows are pruned cheaply by
  `Loopctl.Workers.RateLimitCounterCleanupWorker` (a bounded index-range delete
  on `window_start`), not on the hot path.

  ## Access path — `Loopctl.AdminRepo`, cross-tenant

  `rate_limit_counters` is a GLOBAL table with NO `tenant_id`; tenant/key
  isolation lives entirely in the `bucket` STRING (`"key:<uuid>"`,
  `"tenant:<uuid>"`, `"provider_admission:embedding:<uuid>"`, ...). The limiter
  runs CROSS-TENANT (one shared store), so — exactly like `system_configs` — it
  is accessed via `Loopctl.AdminRepo` (BYPASSRLS in prod, table owner in
  dev/test), NEVER `Loopctl.Repo` (whose RLS would block cross-tenant writes).
  RLS is ENABLEd on the table only to deny that low-privilege role.

  ## Fail-OPEN (parity with the ETS/Hammer path and US-37.1)

  A monitoring/limiter fault must NEVER block all traffic. ANY error raised,
  exited, or thrown by the DB call is caught, LOGGED, and returns `{:allow, 0}`
  (allow the request, full remaining) — the limiter degrades to "no gate", never
  to "deny everything". `{:allow, 0}` (not `{:error, _}`) is returned
  deliberately so callers that only branch on `{:allow, _}` / `{:deny, _}` (the
  web plug) stay robust without a call-site change.
  """

  @behaviour Loopctl.RateLimiter.Behaviour

  require Logger

  alias Loopctl.AdminRepo

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
  defp fail_open(bucket, detail) do
    Logger.warning(
      "Loopctl.RateLimiter.Postgres: limiter DB error for bucket=#{bucket}; " <>
        "failing OPEN (allowing request): #{detail}"
    )

    {:allow, 0}
  end

  # Current wall-clock milliseconds via the DI-injected clock (default real
  # system time). Mirrors the injectable clock the other windowed limiters use so
  # window boundaries are deterministically testable.
  defp now_ms, do: DateTime.to_unix(clock().utc_now(), :millisecond)

  defp clock, do: Application.get_env(:loopctl, :clock, Loopctl.Clock.Default)
end
