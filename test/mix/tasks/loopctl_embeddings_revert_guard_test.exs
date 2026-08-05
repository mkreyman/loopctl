defmodule Mix.Tasks.Loopctl.EmbeddingsRevertGuardTest do
  @moduledoc """
  GH #578 review — `mix loopctl.embeddings revert` used to write the flag and print
  plain success on ANY install, including one whose legacy `articles.embedding` HNSW
  index the #578 migration had already retired. There the revert is a tenant-wide
  semantic-search outage, so the task now checks the index first.

  What is tested here is the two PUBLIC pieces of that guard: the predicate the
  refusal branches on, and the rebuild text it prints. The refusal branch itself is
  not driven end-to-end on purpose — `dispatch/1` writes the read flag into
  VM-global `:persistent_term`, which no async test may mutate.

  Likewise, the predicate is exercised against the migrated schema, where the legacy
  index EXISTS — i.e. the shipped-default install, which must still be allowed to
  revert. The absent-index case would need a `DROP INDEX` on the shared `articles`
  table, taking ACCESS EXCLUSIVE on it for the whole transaction and stalling every
  concurrently running async test that reads articles. That is the exact global-state
  hazard `Loopctl.Repo.HnswIndex`'s moduledoc exists to avoid, so it is not simulated.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Repo.HnswIndex
  alias Mix.Tasks.Loopctl.Embeddings, as: Task

  setup :verify_on_exit!

  describe "legacy_hnsw_index_present?/0" do
    test "is true on the migrated schema — the shipped default may still revert" do
      assert Task.legacy_hnsw_index_present?()
    end

    test "the index it finds is genuinely an hnsw index over articles.embedding" do
      # Non-vacuity: a join that silently matched NOTHING would make the guard refuse
      # every revert, and a join that matched the WRONG relation (the side table, say)
      # would make it allow one onto a column with no index at all. Assert the catalog
      # fact the predicate claims, independently.
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT idx.relname, am.amname, i.indisvalid
        FROM pg_index i
        JOIN pg_class idx ON idx.oid = i.indexrelid
        JOIN pg_class tbl ON tbl.oid = i.indrelid
        JOIN pg_am am ON am.oid = idx.relam
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE tbl.relname = 'articles'
          AND a.attname = 'embedding'
          AND am.amname = 'hnsw'
        """)

      refute rows == [], "no HNSW index over articles.embedding — run mix ecto.migrate"
      assert Enum.all?(rows, fn [_name, am, valid] -> am == "hnsw" and valid end)

      # Detection is by CAPABILITY, so it must catch the index whatever name it lives
      # under — but on a reconciled schema (US-27.14) that name is the canonical one,
      # and the rebuild the task prints names it.
      names = Enum.map(rows, fn [name, _am, _valid] -> name end)
      assert HnswIndex.canonical_index_name("articles") in names
    end
  end

  describe "unindexed_revert_warning/0" do
    test "names the rebuild, single-sourced from HnswIndex so it cannot drift" do
      warning = Task.unindexed_revert_warning()

      assert warning =~ "CREATE INDEX CONCURRENTLY"
      assert warning =~ HnswIndex.canonical_index_name("articles")
      assert warning =~ "articles USING hnsw (embedding vector_cosine_ops)"

      # The build params are the load-bearing part: a rebuild at different `m` /
      # `ef_construction` than every other HNSW index on the instance is a silent
      # recall/latency change. They come from HnswIndex, never a literal here.
      assert warning =~ HnswIndex.with_params_clause()
    end

    test "warns about maintenance_work_mem, which a ~657 MB build silently needs" do
      assert Task.unindexed_revert_warning() =~ "maintenance_work_mem"
    end

    test "names the failure the code actually produces, and denies the one it does not" do
      # The cancel is a raised Postgrex.Error (57014) rendered 504 db_statement_timeout.
      # `heavy_read_overloaded` is a TenantGate-shed tuple and is the ONLY thing the
      # labelled keyword degrade matches — an operator told to expect a graceful
      # degrade would wait for results that never come.
      warning = Task.unindexed_revert_warning()

      assert warning =~ "504 db_statement_timeout"
      assert warning =~ "NOT the heavy_read_overloaded tuple"
    end
  end

  describe "Loopctl.Knowledge.ScaleSeed.hnsw_index_present?/0 (GH #578 widening)" do
    test "the side table carries its own HNSW index, so a cut-over install has one" do
      # The precondition that makes the widened scope meaningful: after the #578 drop,
      # `articles` has no HNSW index and `article_embeddings` is the only relation that
      # can satisfy the scale gate. If the side table carried none, widening the
      # predicate would buy nothing and the gate would still abort.
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT 1
        FROM pg_indexes idx
        JOIN pg_class cls ON cls.relname = idx.indexname
        JOIN pg_am am ON am.oid = cls.relam
        WHERE idx.tablename = 'article_embeddings'
          AND am.amname = 'hnsw'
        LIMIT 1
        """)

      refute rows == [], "article_embeddings carries no HNSW index — run mix ecto.migrate"
      assert ScaleSeed.hnsw_index_present?()
    end
  end
end
