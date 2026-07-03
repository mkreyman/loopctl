ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Loopctl.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Loopctl.AdminRepo, :manual)

# VM-global :atomics counter backing `Loopctl.Fixtures.next_story_number/0`.
# Initialized once here, single-threaded, before any (async) test runs, so the
# counter is a single shared source of guaranteed-unique story numbers — no
# lazy-init race. `:atomics.add_get/3` is atomic across all test processes.
:persistent_term.put(
  {Loopctl.Fixtures, :story_number_counter},
  :atomics.new(1, signed: false)
)

# audit_log is time-partitioned. The create_audit_log migration seeds partitions for a
# window anchored to WHEN IT RAN (its month + 3). A fresh CI DB migrated today therefore
# has no partition for the FIXED past-dated rows many tests insert (e.g. ~U[2026-06-24]),
# nor for future months as time advances — so audit inserts fail with "no partition".
# (Prod is unaffected: the nightly AuditPartitionWorker keeps the window ahead.) Ensure a
# generous window here. It must be COMMITTED DDL, so run it unboxed — a plain query would
# execute inside the sandbox transaction and be rolled back before any test sees it.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Loopctl.Repo, fn ->
  Loopctl.Workers.AuditPartitionWorker.ensure_partitions(back: 12)
end)

# Scale tests (US-27.1) are opt-in: they seed large corpora, commit rows
# directly to the DB, and run ANALYZE. They must NEVER run inside the normal
# async sandbox suite — doing so would silently produce n≈0 statistics.
#
# To run scale tests:
#   SCALE_TESTS=true mix test --only scale
#
# Plain `mix test` always excludes :scale.
# ExUnit.configure(exclude: ...) REPLACES the exclude list — it does not merge.
# Both exclusions must be specified in a single call so neither overwrites the other.
#
# To run scale tests:
#   SCALE_TESTS=true mix test --only scale
#
# To run nightly scale tests:
#   SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly
#
# Plain `mix test` always excludes both :scale and :scale_nightly.
scale_excluded = if System.get_env("SCALE_TESTS"), do: [], else: [:scale]
nightly_excluded = if System.get_env("SCALE_NIGHTLY"), do: [], else: [:scale_nightly]

# :pgbouncer e2e (US-27.13) needs a real pgbouncer in front of Postgres (no pgbouncer
# locally / in the default CI Test job). It runs only when PGBOUNCER_URL is set — the
# dedicated CI pgbouncer-e2e job, or locally against a transaction-mode pgbouncer:
#   PGBOUNCER_URL=postgres://postgres:postgres@127.0.0.1:6432/loopctl_test \
#     mix test --include pgbouncer test/loopctl/pgbouncer_startup_params_test.exs
pgbouncer_excluded = if System.get_env("PGBOUNCER_URL"), do: [], else: [:pgbouncer]

# :requires_ipv6 — the SSRF IP-pinning Host-header regression test stands up a
# loopback HTTP server bound to ::1 (the ONLY way to exercise Req.Finch.run/1's
# IPv6 host-injection path). Probe ::1 bindability once; skip (not error) the
# tagged test on environments lacking IPv6 loopback, while keeping full coverage
# where IPv6 exists (local dev, ubuntu-latest CI). IPv4 round-trip stays always-on.
ipv6_excluded =
  case :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, active: false]) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      []

    {:error, _reason} ->
      [:requires_ipv6]
  end

ExUnit.configure(
  exclude: scale_excluded ++ nightly_excluded ++ pgbouncer_excluded ++ ipv6_excluded
)
