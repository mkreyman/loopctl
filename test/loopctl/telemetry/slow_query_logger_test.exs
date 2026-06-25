defmodule Loopctl.Telemetry.SlowQueryLoggerTest do
  @moduledoc """
  US-27.4 (AC-27.4.4/.5/.6): the SlowQueryLogger telemetry handler logs queries over
  the configurable threshold (with duration + source, no raw SQL) and stays silent for
  fast queries. async: false so the global log capture isn't polluted by concurrent
  async tests' queries.
  """
  use Loopctl.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Repo
  alias Loopctl.Telemetry.SlowQueryLogger

  # The handler is attached at app boot (Application.start). Default threshold = 1000ms.

  test "logs a query slower than the threshold with duration + source + endpoint (if provided), NOT the raw SQL" do
    # Test without endpoint (direct query, not through heavy_read_opts)
    log = capture_log(fn -> Repo.query!("SELECT pg_sleep(1.1)") end)
    assert log =~ "slow_query"
    assert log =~ "duration_ms="
    assert log =~ "endpoint="
    # AC-27.4.4 disclosure: the raw SQL / function text is never logged.
    refute log =~ "pg_sleep"
  end

  test "logs the endpoint when the query carries Ecto :telemetry_options (heavy_read_opts path)" do
    import Ecto.Query

    slow =
      from(x in fragment("generate_series(1, 1)"),
        where: fragment("pg_sleep(1.1) IS NULL"),
        select: fragment("1")
      )

    log = capture_log(fn -> Repo.all(slow, telemetry_options: [endpoint: :probe_endpoint]) end)

    assert log =~ "slow_query"
    assert log =~ "endpoint=probe_endpoint"
  end

  test "does NOT log a query under the threshold (no per-query noise)" do
    log = capture_log(fn -> Repo.query!("SELECT 1") end)
    refute log =~ "slow_query"
  end

  test "covers all repos uniformly (AdminRepo too)" do
    log = capture_log(fn -> AdminRepo.query!("SELECT pg_sleep(1.1)") end)
    assert log =~ "slow_query"
    assert log =~ "AdminRepo"
  end

  test "threshold_ms/0 reads the configurable value (default 1000)" do
    assert SlowQueryLogger.threshold_ms() == 1_000
  end

  test "logs include tenant_id when seeded by the SeedTenantMetadata plug" do
    # Simulate the SeedTenantMetadata plug seeding the Logger metadata.
    tenant_id = "test-tenant-123"
    Logger.metadata(tenant_id: tenant_id)

    log = capture_log(fn -> Repo.query!("SELECT pg_sleep(1.1)") end)

    assert log =~ "slow_query"
    assert log =~ "tenant_id=#{tenant_id}"
    assert log =~ "duration_ms="
  end

  test "telemetry_options with endpoint are preserved and logged through Repo.all" do
    # US-27.4: Ecto :telemetry_options containing [endpoint: :atom] are picked up
    # by the slow-query handler and logged. This is the real code path when
    # heavy_read_opts/1 builds these options and passes them to heavy-read queries.

    slow =
      from(x in fragment("generate_series(1, 1)"),
        where: fragment("pg_sleep(1.1) IS NULL"),
        select: fragment("1")
      )

    log =
      capture_log(fn ->
        # Repo.all with :telemetry_options (not through HeavyRead — direct repo call).
        Repo.all(slow, telemetry_options: [endpoint: :test_endpoint])
      end)

    assert log =~ "slow_query"
    assert log =~ "endpoint=test_endpoint"
    assert log =~ "duration_ms="
  end

  test "heavy_read_opts/1 (the real builder) tags the endpoint and applies a configured override" do
    # The generate_series test above proves the handler LOGS endpoint from
    # telemetry_options; this proves Knowledge.heavy_read_opts/1 — the builder every
    # routed heavy read uses — actually produces that telemetry_options[:endpoint] tag,
    # AND threads a configured per-endpoint statement_timeout override. Together they
    # cover the full endpoint-attribution chain deterministically (no flaky sleeps).
    # An endpoint WITHOUT a per-endpoint override gets the pool-wide DEFAULT
    # statement_timeout (US-27.13: every heavy read is timed via SET LOCAL, since the
    # pgbouncer-rejected startup `:parameters` lever was removed — there is no un-timed
    # "pool default" path). In :test `:heavy_read_statement_timeout_ms` is set to a low
    # 250ms (config/test.exs) so the fast-fire mechanism tests stay sub-second.
    semantic = Knowledge.heavy_read_opts(:semantic_search)
    assert semantic[:telemetry_options] == [endpoint: :semantic_search]
    assert semantic[:timeout] == 15_000
    assert semantic[:statement_timeout] == 250

    # :suggested_links has an override in test config → the SET LOCAL transaction path
    # uses the override value rather than the default.
    suggested = Knowledge.heavy_read_opts(:suggested_links)
    assert suggested[:telemetry_options] == [endpoint: :suggested_links]
    assert suggested[:statement_timeout] == 5_000
  end
end
