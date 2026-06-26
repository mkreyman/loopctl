defmodule Loopctl.HeavyReadRepoTest do
  @moduledoc """
  Mechanism tests for the dedicated heavy-read pool (US-27.11/US-27.13): the server-side
  `statement_timeout` applied PER-READ via `SET LOCAL` inside a transaction (AC-27.11.3/.6),
  and the `hnsw.ef_search` GUC reachability (AC-27.11.3).

  US-27.13: the timeout is NO LONGER carried by a connection-startup `:parameters` — Fly
  MPG's pgbouncer rejects a `statement_timeout` startup parameter (`08P01`), which
  crash-loops the whole pool in prod. The old `:parameters` tests "passed" only because the
  test suite connects to DIRECT Postgres (which accepts the param) — the false confidence
  that hid the outage. These tests now exercise the `SET LOCAL`-in-transaction path that is
  pgbouncer-safe and is what the prod read path (`Loopctl.HeavyRead.opts/1` → all/one) uses.
  In test the SET-LOCAL default is a low 250ms (config/test.exs) so the fast-fire assertion
  is sub-second.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.HeavyReadRepo

  import Ecto.Query

  describe "per-read statement_timeout via SET LOCAL (pgbouncer-safe — US-27.13)" do
    test "SET LOCAL statement_timeout inside a transaction takes effect (SHOW reflects it)" do
      {:ok, shown} =
        HeavyReadRepo.transaction(fn ->
          HeavyReadRepo.query!("SET LOCAL statement_timeout = 250")
          %{rows: [[value]]} = HeavyReadRepo.query!("SHOW statement_timeout")
          value
        end)

      assert shown == "250ms"
    end

    test "a query exceeding the SET LOCAL statement_timeout fast-fails with 57014 query_canceled (AC-27.11.6)" do
      # The server cancels at 250ms via the SET LOCAL applied inside the transaction —
      # proof the timeout mechanism the read path relies on actually fires through the
      # dedicated pool (the pgbouncer-safe replacement for the rejected startup param).
      result =
        HeavyReadRepo.transaction(fn ->
          HeavyReadRepo.query!("SET LOCAL statement_timeout = 250")

          case HeavyReadRepo.query("SELECT pg_sleep(1)") do
            {:error, error} -> HeavyReadRepo.rollback(error)
            ok -> ok
          end
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} = result
    end

    test "the SET LOCAL statement_timeout cancels a real Ecto query, not just raw SQL" do
      # Prove the dedicated pool's SET-LOCAL timeout applies to an actual Ecto.Query
      # (built → SQL → run), not only a raw HeavyReadRepo.query/1.
      slow = from(s in fragment("generate_series(1, 100000000)"), select: count())

      result =
        HeavyReadRepo.transaction(fn ->
          HeavyReadRepo.query!("SET LOCAL statement_timeout = 250")

          try do
            HeavyReadRepo.all(slow)
            :no_cancel
          rescue
            e in Postgrex.Error -> HeavyReadRepo.rollback(e)
          end
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} = result
    end

    test "a higher SET LOCAL statement_timeout lifts the default within its transaction (export lever)" do
      # US-27.16 streamed exports hold a connection for minutes — longer than the fast-read
      # default. SET LOCAL inside the export's transaction scopes the override to that
      # transaction only. A 400ms query (> the 250ms test default) survives under a 5s local.
      result =
        HeavyReadRepo.transaction(fn ->
          HeavyReadRepo.query!("SET LOCAL statement_timeout = 5000")
          HeavyReadRepo.query!("SELECT pg_sleep(0.4)")
          :ok
        end)

      assert result == {:ok, :ok}
    end
  end

  describe "hnsw.ef_search reachability (AC-27.11.3)" do
    test "SHOW hnsw.ef_search returns the default 40 through the heavy-read pool" do
      # Touch a vector op first so pgvector's library + custom GUC are registered for
      # this session, then read the GUC. We deliberately keep the default (40); the
      # ALTER ROLE lever for raising it is documented in docs/runbooks/knowledge-scale.md.
      HeavyReadRepo.query!("SELECT '[1,2,3]'::vector")
      %{rows: [[value]]} = HeavyReadRepo.query!("SHOW hnsw.ef_search")
      assert value == "40"
    end
  end
end
