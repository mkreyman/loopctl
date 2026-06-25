defmodule Loopctl.Telemetry.SlowQueryLoggerTest do
  @moduledoc """
  US-27.4 (AC-27.4.4/.5/.6): the SlowQueryLogger telemetry handler logs queries over
  the configurable threshold (with duration + source, no raw SQL) and stays silent for
  fast queries. async: false so the global log capture isn't polluted by concurrent
  async tests' queries.
  """
  use Loopctl.DataCase, async: false

  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
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
end
