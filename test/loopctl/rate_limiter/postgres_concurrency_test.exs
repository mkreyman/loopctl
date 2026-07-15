defmodule Loopctl.RateLimiter.PostgresConcurrencyTest do
  @moduledoc """
  TC-38.2.2 / AC-38.2.4 — the story's CENTRAL correctness claim: two concurrent
  nodes racing the same bucket cannot exceed the global budget ("no
  read-modify-write race").

  This MUST run `async: false` against COMMITTED rows over INDEPENDENT DB
  connections. The sandbox-transaction version of this test (one checked-out
  connection shared via `Sandbox.allow`) is worthless here: DBConnection
  serializes every statement through that one connection, so the racers never
  actually execute concurrently at the DB and a naive `SELECT count` →
  `UPDATE count+1` (a real read-modify-write race) would pass identically. Only
  genuinely concurrent connections hitting the SAME committed
  `(bucket, window_start)` row can distinguish the atomic
  `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` (Postgres row-lock serialized)
  from a lost-update race.

  We therefore run each racer under `Sandbox.unboxed_run/2` (the codebase's scale
  gates use the same pattern for `Loopctl.AdminRepo`) so its upserts COMMIT to a
  real connection, and clean the single global bucket up afterwards. The bucket
  key is uniquified so nothing else touches it; `async: false` guarantees no
  other test observes the committed rows in the window before cleanup.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.RateLimiter.Postgres

  @window_ms 60_000

  # Pin the wall clock to a FIXED instant (not real time) so every racer buckets
  # to the SAME window_start regardless of when it runs. This still exercises
  # genuine cross-connection DB concurrency against ONE committed
  # `(bucket, window_start)` row — the property under test — but removes the
  # minute-boundary flake: with real time, the 4×40 upserts could straddle a
  # unix-minute boundary, roll the fixed window over mid-test, reset the shared
  # counter, and break BOTH the `allowed == limit` and sorted-counts assertions.
  # (Mirrors the fixed-clock approach the rollover tests in postgres_test.exs use.)
  @fixed_now ~U[2026-07-15 12:00:30Z]

  setup do
    # async: false ⇒ global Mox mode is safe, and the racer Tasks (spawned
    # processes) need the clock stub reachable without per-process allowances.
    # Postgres.check_rate/3 resolves the wall clock through the :clock DI.
    Mox.set_mox_global()
    Mox.stub(Loopctl.MockClock, :utc_now, fn -> @fixed_now end)
    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  test "concurrent independent connections are capped at the GLOBAL budget (not N×)" do
    bucket = "test:cluster-real:#{Ecto.UUID.generate()}"
    limit = 20
    per_caller = 40
    concurrency = 4

    try do
      tasks =
        for _ <- 1..concurrency do
          Task.async(fn ->
            # Each racer gets its OWN committed connection from the pool → true
            # parallel DB access against the shared row.
            unboxed(fn ->
              for _ <- 1..per_caller, do: Postgres.check_rate(bucket, @window_ms, limit)
            end)
          end)
        end

      results = Enum.flat_map(tasks, &Task.await(&1, 30_000))

      allowed = Enum.count(results, &match?({:allow, _}, &1))
      denied = Enum.count(results, &match?({:deny, _}, &1))

      # The COMBINED allowed count is exactly the global budget — never
      # concurrency × limit. A lost-update race would over-admit here.
      assert allowed == limit
      assert denied == concurrency * per_caller - limit

      # Every allowed post-increment count is a distinct value in 1..limit
      # (atomic increment guarantee) — no two racers ever saw the same count.
      allowed_counts = for {:allow, c} <- results, do: c
      assert Enum.sort(allowed_counts) == Enum.to_list(1..limit)
    after
      unboxed(fn ->
        AdminRepo.query!("DELETE FROM rate_limit_counters WHERE bucket = $1", [bucket])
      end)
    end
  end
end
