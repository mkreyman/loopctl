defmodule Loopctl.HeavyReadRepoTest do
  @moduledoc """
  Pool-level mechanism tests for the dedicated heavy-read pool (US-27.11):
  the server-side `statement_timeout` carried by the repo `:parameters`
  (AC-27.11.3/.6) and the `hnsw.ef_search` GUC reachability (AC-27.11.3).

  In the test env the pool's `statement_timeout` is set to a deliberately low
  250ms (config/test.exs) so the fast-fire assertion is sub-second and
  deterministic.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.HeavyReadRepo
  alias Loopctl.Knowledge.Article

  import Ecto.Query

  describe "pool-level statement_timeout via :parameters" do
    test "SHOW statement_timeout reflects the configured pool parameter (AC-27.11.3)" do
      %{rows: [[value]]} = HeavyReadRepo.query!("SHOW statement_timeout")
      assert value == "250ms"
    end

    test "a query exceeding statement_timeout fast-fails with 57014 query_canceled (AC-27.11.6)" do
      # The server cancels at 250ms, well before the client/pool timeout — proof the
      # pool-level mechanism US-27.4 relies on actually fires and releases the conn.
      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
               HeavyReadRepo.query("SELECT pg_sleep(1)")
    end

    test "the pool statement_timeout cancels a real Ecto query, not just raw SQL" do
      # Closes the DI-seam gap: routed reads run on AdminRepo in test, so prove the
      # dedicated pool's timeout applies to an actual Ecto.Query (built → SQL → run),
      # not only a raw HeavyReadRepo.query/1.
      _ = Article
      slow = from(s in fragment("generate_series(1, 100000000)"), select: count())
      err = assert_raise Postgrex.Error, fn -> HeavyReadRepo.all(slow) end
      assert err.postgres.code == :query_canceled
    end

    test "SET LOCAL statement_timeout lifts the pool default within a transaction (export lever)" do
      # US-27.16 streamed exports hold a connection for minutes — longer than the fast-
      # read pool default. SET LOCAL inside the export's transaction scopes the override
      # to that transaction only. A 400ms query (> 250ms pool default) survives under a
      # 5s local override.
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
