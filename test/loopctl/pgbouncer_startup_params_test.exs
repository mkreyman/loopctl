defmodule Loopctl.PgbouncerStartupParamsTest do
  @moduledoc """
  US-27.13 END-TO-END guard: exercises a connection through a REAL pgbouncer (the layer
  Fly Managed Postgres puts in front of Postgres), which the rest of the suite never does.

  The US-27.13 outage shipped because EVERY other test connects to DIRECT Postgres — which
  ACCEPTS a `statement_timeout` connection startup parameter — while prod connects through
  pgbouncer, which REJECTS it with `08P01 unsupported startup parameter` and crash-loops the
  whole pool. No test exercised the pgbouncer layer, so the broken `parameters:` config was
  green in CI and dead in prod.

  This test closes that gap empirically. It is tagged `:pgbouncer` and EXCLUDED from the
  default suite (no pgbouncer locally); it runs in the dedicated CI `pgbouncer-e2e` job
  (postgres + pgbouncer services) and locally when you point `PGBOUNCER_URL` at a pgbouncer
  in transaction-pooling mode. It asserts:

    1. a connection carrying a `statement_timeout` STARTUP parameter cannot serve queries
       through pgbouncer (reproduces the outage — would have RED-flagged the bad config);
    2. a clean connection (no such startup param) works through pgbouncer; and
    3. the FIX's mechanism — a server-side `statement_timeout` applied via `SET LOCAL`
       inside a transaction — actually ENFORCES through pgbouncer (cancels a slow query).
  """
  use ExUnit.Case, async: false

  @moduletag :pgbouncer

  setup do
    url =
      System.get_env("PGBOUNCER_URL") ||
        flunk(
          "PGBOUNCER_URL must be set to run the :pgbouncer e2e (e.g. " <>
            "postgres://postgres:postgres@127.0.0.1:6432/loopctl_test). It is wired in the " <>
            "CI pgbouncer-e2e job; locally, start pgbouncer in transaction mode and export it."
        )

    {:ok, base: parse_url(url)}
  end

  test "a `statement_timeout` STARTUP parameter cannot serve queries through pgbouncer (reproduces US-27.13)",
       %{base: base} do
    # pgbouncer rejects the non-allowlisted startup parameter at connect (08P01), so the
    # pool never establishes a usable connection — a checkout fails. Trap the linked exit so
    # the rejection surfaces as a captured error rather than killing the test.
    Process.flag(:trap_exit, true)
    {:ok, conn} = Postgrex.start_link(base ++ [parameters: [statement_timeout: "10000"]])

    result =
      try do
        Postgrex.query(conn, "SELECT 1", [], timeout: 4_000)
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:exit, reason}
      end

    refute match?({:ok, _}, result),
           "a statement_timeout STARTUP parameter must NOT yield a working connection through " <>
             "pgbouncer — it is rejected with 08P01 (the US-27.13 outage). Got: #{inspect(result)}"
  end

  test "a clean connection (no statement_timeout startup param) works through pgbouncer", %{
    base: base
  } do
    {:ok, conn} = Postgrex.start_link(base ++ [parameters: []])

    assert {:ok, %Postgrex.Result{rows: [[1]]}} =
             Postgrex.query(conn, "SELECT 1", [], timeout: 4_000)
  end

  test "SET LOCAL statement_timeout ENFORCES through pgbouncer (the fix's mechanism)", %{
    base: base
  } do
    # The pgbouncer-safe way to get a server-side statement_timeout: SET LOCAL inside a
    # transaction (HeavyRead.opts/1 → all/one). Prove it actually cancels a slow query
    # through the proxy — so the fix is verified against the real layer, not just direct PG.
    {:ok, conn} = Postgrex.start_link(base ++ [parameters: []])

    outcome =
      Postgrex.transaction(conn, fn c ->
        Postgrex.query!(c, "SET LOCAL statement_timeout = 200", [])

        case Postgrex.query(c, "SELECT pg_sleep(1)", []) do
          {:error, %Postgrex.Error{postgres: %{code: code}}} -> Postgrex.rollback(c, code)
          {:ok, _} -> Postgrex.rollback(c, :not_cancelled)
        end
      end)

    assert outcome == {:error, :query_canceled},
           "SET LOCAL statement_timeout must cancel an over-budget query through pgbouncer; got #{inspect(outcome)}"
  end

  # Parse a postgres:// URL into Postgrex start_link opts (fail-fast pool so a rejected
  # connection errors quickly instead of queueing).
  defp parse_url(url) do
    uri = URI.parse(url)
    {user, pass} = userinfo(uri.userinfo)

    [
      hostname: uri.host || "127.0.0.1",
      port: uri.port || 6432,
      username: user,
      password: pass,
      database: String.trim_leading(uri.path || "/loopctl_test", "/"),
      backoff_type: :stop,
      pool_size: 1,
      queue_target: 300,
      queue_interval: 600
    ]
  end

  defp userinfo(nil), do: {"postgres", "postgres"}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [u, p] -> {u, p}
      [u] -> {u, nil}
    end
  end
end
