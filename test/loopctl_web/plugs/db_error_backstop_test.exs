defmodule LoopctlWeb.Plugs.DBErrorBackstopTest do
  @moduledoc """
  US-27.3: the endpoint-level backstop must give EVERY controller — not just
  `suggested_links` — the same structured SQLSTATE log (AC-27.3.3) and the same
  no-raw-SQL-leak guarantee (AC-27.3.8) when a DB exception escapes a controller
  action UNCAUGHT (i.e. not via the FallbackController rescue path).

  We exercise the real backstop plug end-to-end through the endpoint by injecting
  (config-based DI + Mox) a router that raises a DB exception uncaught, the same
  way an un-rescued DB-touching controller would.
  """
  use LoopctlWeb.ConnCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Mox

  setup :verify_on_exit!

  # A Postgrex.Error shaped exactly as Postgrex builds a real 57014, whose
  # `query:` carries SQL + a vector literal that WOULD leak if anything called
  # Exception.message/1 on it (Bandit's crash log does exactly that for 5xx). The
  # assertions below prove neither the response, the structured log, NOR the
  # sanitized re-raised exception echoes it.
  defp statement_timeout_error do
    %Postgrex.Error{
      postgres: %{
        code: :query_canceled,
        pg_code: "57014",
        severity: "ERROR",
        message: "canceling statement due to statement timeout"
      },
      query: "SELECT id FROM things ORDER BY embedding <=> '[0.123,0.456]'::vector LIMIT 5"
    }
  end

  # Raise the DB exception the way it reaches the endpoint from a controller
  # action: wrapped in a Plug.Conn.WrapperError carrying the dispatched conn (so
  # controller/action/assigns are populated for the structured log).
  defp raise_uncaught(conn, exception) do
    expect(Loopctl.MockBackstopRouter, :call, fn router_conn, _opts ->
      raise Plug.Conn.WrapperError,
        conn: %{router_conn | private: Map.put(router_conn.private, :phoenix_controller, SomeCtl)},
        kind: :error,
        reason: exception,
        stack: []
    end)

    with_log(fn ->
      assert_raise LoopctlWeb.SanitizedDBError, fn -> LoopctlWeb.Endpoint.call(conn, []) end
    end)
  end

  describe "uncaught DB exception in ANY controller (AC-27.3.3 + AC-27.3.8)" do
    test "57014 is logged with the real SQLSTATE + request_id and re-raised sanitized",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> Plug.Conn.assign(:current_api_key, %{tenant_id: tenant.id})

      {_result, log} = raise_uncaught(conn, statement_timeout_error())

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
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> Plug.Conn.assign(:current_api_key, %{tenant_id: tenant.id})

      expect(Loopctl.MockBackstopRouter, :call, fn router_conn, _opts ->
        raise Plug.Conn.WrapperError,
          conn: router_conn,
          kind: :error,
          reason: statement_timeout_error(),
          stack: []
      end)

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
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> Plug.Conn.assign(:current_api_key, %{tenant_id: tenant.id})

      serialization_error = %Postgrex.Error{
        postgres: %{
          code: :serialization_failure,
          pg_code: "40001",
          severity: "ERROR",
          message: "could not serialize access due to concurrent update"
        }
      }

      expect(Loopctl.MockBackstopRouter, :call, fn router_conn, _opts ->
        raise Plug.Conn.WrapperError,
          conn: router_conn,
          kind: :error,
          reason: serialization_error,
          stack: []
      end)

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
      expect(Loopctl.MockBackstopRouter, :call, fn router_conn, _opts ->
        raise Plug.Conn.WrapperError,
          conn: router_conn,
          kind: :error,
          reason: %RuntimeError{message: "boom"},
          stack: []
      end)

      assert_raise RuntimeError, "boom", fn -> LoopctlWeb.Endpoint.call(conn, []) end
    end
  end
end
