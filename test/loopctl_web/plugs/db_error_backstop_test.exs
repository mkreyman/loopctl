defmodule LoopctlWeb.Plugs.DBErrorBackstopTest do
  @moduledoc """
  US-27.3: the endpoint-level backstop must give EVERY controller — not just
  `suggested_links` — the same structured SQLSTATE log (AC-27.3.3) and the same
  no-raw-SQL-leak guarantee (AC-27.3.8) when a DB exception escapes a controller
  action UNCAUGHT (i.e. not via the FallbackController rescue path).

  We exercise the real backstop plug end-to-end through the real endpoint by
  driving the REAL test router (`Loopctl.Test.BackstopRouter`, wired via
  config/test.exs) with the opt-in `x-test-raise-db-error` header, which makes it
  raise a DB exception uncaught exactly the way an un-rescued DB-touching
  controller would. No global Mox mock of the router is involved.
  """
  use LoopctlWeb.ConnCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  setup :verify_on_exit!

  # Drive the real test router to raise the given DB-error `kind` uncaught and
  # assert a SanitizedDBError propagates, capturing the structured log.
  defp raise_uncaught(conn, kind) do
    conn = put_req_header(conn, "x-test-raise-db-error", kind)

    with_log(fn ->
      assert_raise LoopctlWeb.SanitizedDBError, fn -> LoopctlWeb.Endpoint.call(conn, []) end
    end)
  end

  # Only the Bearer key — the identity is resolved by the REAL auth plugs INSIDE the test
  # router. Pre-assigning `:current_api_key` on the endpoint conn would make the tenant_id
  # assertions vacuous for the EXIT path, which unwinds the router frame in production.
  defp authed_conn(conn) do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    {put_req_header(conn, "authorization", "Bearer #{raw_key}"), tenant}
  end

  describe "uncaught DB exception in ANY controller (AC-27.3.3 + AC-27.3.8)" do
    test "57014 is logged with the real SQLSTATE + request_id and re-raised sanitized",
         %{conn: conn} do
      {conn, tenant} = authed_conn(conn)

      {_result, log} = raise_uncaught(conn, "57014")

      # AC-27.3.3: structured SQLSTATE line emitted on the UNCAUGHT path too.
      assert log =~ "sqlstate=57014"
      assert log =~ "mapped_code=db_statement_timeout"
      assert log =~ "request_id="
      assert log =~ "tenant_id=#{tenant.id}"

      # AC-27.3.8: the structured log never echoes the raw SQL / vector / params.
      refute log =~ "SELECT"
      refute log =~ "embedding <=>"
      refute log =~ "::vector"
      refute log =~ "0.123"
    end

    test "the re-raised SanitizedDBError message never contains the raw query (AC-27.3.8)",
         %{conn: conn} do
      {conn, _tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "57014")

      # Bandit's crash log formats the re-raised exception via Exception.format/3
      # (-> message/1) for any 5xx. Prove our sanitized stand-in's message — the
      # thing that lands in that crash log — carries no SQL/vector/params.
      {_, _log} =
        with_log(fn ->
          error =
            assert_raise LoopctlWeb.SanitizedDBError, fn ->
              LoopctlWeb.Endpoint.call(conn, [])
            end

          message = Exception.message(error)
          assert message =~ "57014"
          assert message =~ "db_statement_timeout"
          refute message =~ "SELECT"
          refute message =~ "embedding <=>"
          refute message =~ "::vector"
          refute message =~ "0.123"

          # The pinned 504 status survives so ErrorJSON renders the right body.
          assert Plug.Exception.status(error) == 504
        end)
    end

    test "serialization failure (40001) re-raises a 503 SanitizedDBError carrying db_serialization_failure",
         %{conn: conn} do
      {conn, _tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "40001")

      {_, log} =
        with_log(fn ->
          error =
            assert_raise LoopctlWeb.SanitizedDBError, fn ->
              LoopctlWeb.Endpoint.call(conn, [])
            end

          # AC-27.3.* / Finding #2: the escaped 503 is NOT coarsened to
          # db_unavailable — its mapped_code is the precise class.
          assert error.mapped_code == "db_serialization_failure"
          assert Plug.Exception.status(error) == 503
        end)

      assert log =~ "sqlstate=40001"
      assert log =~ "mapped_code=db_serialization_failure"
    end
  end

  describe "non-DB exceptions are NOT translated (let-it-crash)" do
    test "a plain RuntimeError propagates unchanged", %{conn: conn} do
      {conn, _tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "runtime")

      assert_raise RuntimeError, "boom", fn -> LoopctlWeb.Endpoint.call(conn, []) end
    end
  end

  describe "#558: crash propagation is an EXIT, not a raise" do
    test "a pool exit is translated exactly like the raise path", %{conn: conn} do
      # A `rescue`-only backstop never saw this shape, so the raw reason reached the crash
      # log — carrying the failing statement and its bound parameters.
      {conn, tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "exit-propagation")

      {_, log} =
        with_log(fn ->
          error =
            assert_raise LoopctlWeb.SanitizedDBError, fn ->
              LoopctlWeb.Endpoint.call(conn, [])
            end

          # AC-27.3.8: the REASON that reaches the crash log is now the sanitized stand-in, so
          # `Exception.format/3` cannot render the nested struct's statement or the bound args.
          # Asserting on the backstop's own log line would be vacuous — it never carried them.
          message = Exception.message(error)
          refute message =~ "secret_bound_param"
          refute message =~ "embedding <=>"
          refute message =~ "0.123"
          assert Plug.Exception.status(error) == 500
        end)

      # AC-27.3.3: the exit shape gets the SAME structured SQLSTATE line (and the
      # [:loopctl, :db, :error] counter DBErrorLogger emits with it).
      assert log =~ "sqlstate=42P01"
      assert log =~ "mapped_code=db_error"
      assert log =~ "tenant_id=#{tenant.id}"
    end

    test "the same nested DB error through a Task call element is sanitized too", %{conn: conn} do
      # The leak is a property of the nested struct (statement + bound args), not of WHICH
      # process called the pool, so classifying by the call element alone left this shape raw.
      {conn, tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "exit-task")

      {_, log} =
        with_log(fn ->
          error =
            assert_raise LoopctlWeb.SanitizedDBError, fn -> LoopctlWeb.Endpoint.call(conn, []) end

          refute Exception.message(error) =~ "embedding <=>"
        end)

      assert log =~ "sqlstate=42P01"
      # The exit path attributes the fault WITHOUT the router frame (Logger metadata).
      assert log =~ "tenant_id=#{tenant.id}"
    end

    test "a NON-DB exception nested under a pool call element keeps its identity",
         %{conn: conn} do
      # Dressing it as a `DBConnection.ConnectionError` advertised a permanent defect as a
      # retryable 503 and erased the only record of what actually failed.
      {conn, _tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "exit-nested-runtime")

      {reason, log} = with_log(fn -> catch_exit(LoopctlWeb.Endpoint.call(conn, [])) end)

      assert {{%RuntimeError{message: "pool process defect"}, []}, {DBConnection, :run, []}} =
               reason

      refute log =~ "db_error mapped to HTTP"
    end

    test "a FOREIGN exit is re-exited untouched and not attributed to the database",
         %{conn: conn} do
      {conn, _tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "exit-foreign")

      {reason, log} =
        with_log(fn -> catch_exit(LoopctlWeb.Endpoint.call(conn, [])) end)

      assert {:timeout, {GenServer, :call, _args}} = reason
      refute log =~ "DBErrorBackstop"
      refute log =~ "db_error mapped to HTTP"
    end
  end
end
