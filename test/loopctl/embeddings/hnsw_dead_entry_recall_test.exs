defmodule Loopctl.Embeddings.HnswDeadEntryRecallTest do
  @moduledoc """
  #645 — the reproduction of the long-running `left: []` vector-recall flake, and the
  evidence for the fix `test/test_helper.exs` applies.

  ## The mechanism, measured rather than theorised

  Sandbox rolls back every test, and a rolled-back INSERT leaves its HNSW entry in the
  shared graph until vacuum. A row inserted afterwards links to its nearest neighbours —
  which by then are all DEAD elements — and pgvector's scan SKIPS dead elements rather than
  traversing through them. The live row ends up UNREACHABLE from the graph entry point, so
  the ANN returns NOTHING while a `count()` on the same connection says the row is right
  there.

  That is exactly the signature #645 captured from CI: `rows=0`, **no** `Rows Removed by
  Filter` line (nothing was filtered — the candidates were never visible), and buffer
  traffic an order of magnitude above a clean index.

  It settles what #645 left open, and it retires two standing hypotheses:

    * **Candidate starvation is not needed.** There are no live competitors here at all —
      one visible row, and the scan still returns nothing.
    * **No ANN knob fixes it.** This test asserts the failure under `hnsw.iterative_scan =
      off`, under `relaxed_order`, and under `hnsw.ef_search = 1000`. Reachability is not a
      breadth problem. That is why `ef_search`, exact-scan forcing, `iterative_scan` and
      retry-on-empty were each tried and each failed.

  The remedy is therefore not a fifth knob: VACUUM is the only thing that repairs the
  graph, and it repairs it completely. `Loopctl.DataCase.vacuum_vector_indexes/0` does that
  before each test in the modules that produced the signature (opt in with
  `@moduletag :vacuum_vector_indexes`), and the last assertion here is that half — the same
  poisoned index, vacuumed, answers correctly.

  `async: false`: it deliberately fills a shared graph with dead entries.
  """
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo

  # Comfortably above pgvector's default `hnsw.ef_search` of 40. Small enough to stay a
  # sub-second test.
  @dead_entries 120
  @dim 1536
  # The real per-dimension index the request path uses — this test measures the shipped
  # one, not a stand-in.
  @index "article_embeddings_hnsw_dim_1536_idx"

  # Start from a REPAIRED graph, so the poisoning below is the only thing this test is
  # measuring — not whatever the modules before it left behind.
  setup do
    Loopctl.DataCase.vacuum_vector_indexes()
    :ok
  end

  # A cluster of near-identical decoys around the query direction, and one live row
  # pointing a DIFFERENT direction. Making the live row far from the query is what makes
  # the failure deterministic: with random vectors it would land inside the ef_search
  # window often enough to become its own flake.
  defp decoy_vec(index) do
    List.duplicate(0.0, @dim)
    |> List.replace_at(0, 1.0)
    |> List.replace_at(2 + rem(index, 100), 0.05)
  end

  defp query_vec, do: List.replace_at(List.duplicate(0.0, @dim), 0, 1.0)
  defp live_vec, do: List.replace_at(List.duplicate(0.0, @dim), 1, 1.0)

  # Insert `@dead_entries` embeddings in a transaction that really ABORTS, on a connection
  # outside the sandbox. That is what every rolled-back test in the suite does, concentrated
  # — and doing it unboxed is what makes the dead tuples vacuumable later, so this test can
  # demonstrate the remedy as well as the failure.
  defp poison_index do
    Sandbox.unboxed_run(AdminRepo, fn ->
      AdminRepo.transaction(&seed_doomed_embeddings/0)
    end)
  end

  defp seed_doomed_embeddings do
    tenant = fixture(:tenant)

    Enum.each(1..@dead_entries, fn index ->
      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Dead entry #{index}",
          status: :published
        })

      insert_embedding(tenant.id, article.id, decoy_vec(index))
    end)

    AdminRepo.rollback(:poison)
  end

  defp insert_embedding(tenant_id, article_id, vector) do
    AdminRepo.query!(
      """
      INSERT INTO article_embeddings
        (id, tenant_id, article_id, dim, embedding, live_denorm, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, $4::vector, true, now(), now())
      """,
      [Ecto.UUID.dump!(tenant_id), Ecto.UUID.dump!(article_id), @dim, Pgvector.new(vector)]
    )
  end

  # The ANN read, with its plan PINNED.
  #
  # The predicate is the index's own (`dim` + `live_denorm`) rather than the tenant filter
  # the production query adds, and `enable_seqscan` is off. Both are about plan stability,
  # not about the mechanism: on a table this small the costs sit within noise of each
  # other, which is the same plan lottery the flake itself rides (the moduledoc of
  # `embeddings_side_table_reads_test.exs` measured 7 exact / 3 HNSW over ten runs of an
  # unchanged database). A test that only sometimes reaches the ANN proves nothing on the
  # runs it does not. `assert_ann_plan!/0` is what keeps the pin honest.
  defp ann_read(opts) do
    AdminRepo.query!("SET LOCAL hnsw.iterative_scan = #{Keyword.fetch!(opts, :mode)}", [])
    AdminRepo.query!("SET LOCAL hnsw.ef_search = #{Keyword.get(opts, :ef_search, 40)}", [])
    AdminRepo.query!("SET LOCAL enable_seqscan = off", [])
    # `enable_sort = off` as well: after the vacuum the index is small again and the
    # planner prefers a btree scan plus an explicit sort, which would silently stop
    # measuring the ANN. Penalising the sort leaves the index-provided ordering as the
    # cheap path in both the poisoned and the repaired state.
    AdminRepo.query!("SET LOCAL enable_sort = off", [])
    assert_ann_plan!()

    %{rows: rows} = AdminRepo.query!(ann_sql(), ann_params())
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  # The same read with the ANN unavailable — an exact plan, which is what the default suite
  # now always gets.
  defp exact_read do
    AdminRepo.query!("SET LOCAL enable_seqscan = on", [])
    AdminRepo.query!("SET LOCAL enable_indexscan = off", [])

    %{rows: rows} = AdminRepo.query!(ann_sql(), ann_params())
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp assert_ann_plan! do
    %{rows: rows} = AdminRepo.query!("EXPLAIN " <> ann_sql(), ann_params())
    plan = rows |> List.flatten() |> Enum.join("\n")

    assert plan =~ @index,
           "expected the ANN plan to be pinned, got: #{plan |> String.split("\n") |> hd()}"
  end

  defp ann_sql do
    """
    SELECT article_id FROM article_embeddings
    WHERE dim = $1 AND live_denorm
    ORDER BY (embedding::vector(#{@dim})) <=> $2::vector
    LIMIT 30
    """
  end

  defp ann_params, do: [@dim, Pgvector.new(query_vec())]

  describe "dead HNSW entries left by rolled-back test transactions" do
    test "make a visible row unreachable by ANN under every knob, and a vacuum repairs it" do
      poison_index()

      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Live"})
      insert_embedding(tenant.id, article.id, live_vec())

      # The row is unambiguously VISIBLE. This is hypothesis (a) from the moduledoc of
      # `embeddings_side_table_reads_test.exs`, killed here by construction rather than by
      # a post-hoc count.
      assert %{rows: [[1]]} =
               AdminRepo.query!(
                 "SELECT count(*) FROM article_embeddings WHERE dim = $1 AND live_denorm",
                 [@dim]
               )

      # THE FLAKE.
      assert ann_read(mode: "off") == []

      # AND NO KNOB REACHES IT. Iterative scan is the documented pgvector remedy for
      # "fewer rows than expected", and a wider window is the intuitive one; neither helps,
      # because the live element is not distant, it is unreachable.
      assert ann_read(mode: "relaxed_order") == []
      assert ann_read(mode: "relaxed_order", ef_search: 1000) == []

      # An exact plan over the SAME table returns it, which is what makes this a graph
      # defect rather than a visibility one.
      assert exact_read() == [article.id]

      # THE FIX. The dead entries came from a transaction that aborted before this test
      # began, so they are dead to every snapshot and vacuum can remove them.
      Loopctl.DataCase.vacuum_vector_indexes()

      assert ann_read(mode: "off") == [article.id]
    end
  end
end
