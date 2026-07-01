ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Loopctl.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Loopctl.AdminRepo, :manual)

# audit_log is time-partitioned. The create_audit_log migration seeds partitions for a
# fixed window (its month + 3), which ELAPSES as the wall clock advances — so after a
# month rollover the test DB has no partition for "now" and every audit insert fails
# (prod is unaffected: the nightly AuditPartitionWorker keeps the window ahead). Ensure
# the current + lookahead partitions exist here (idempotent CREATE IF NOT EXISTS DDL) so
# the suite doesn't depend on when the migration happened to run.
Loopctl.Workers.AuditPartitionWorker.ensure_partitions()

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
ExUnit.configure(exclude: scale_excluded ++ nightly_excluded ++ pgbouncer_excluded)
