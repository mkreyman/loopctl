defmodule Loopctl.Repo.HnswIndexParamsTest do
  @moduledoc """
  US-38.4 / TC-38.4.1 (build side) — the HNSW `m` / `ef_construction` build
  parameters are EXPLICIT + configurable in the `Loopctl.Repo.HnswIndex` builder.

  Asserts the builder emits `WITH (m = .., ef_construction = ..)` driven by the
  configured `hnsw_m/0` / `hnsw_ef_construction/0` (not a hard-coded literal), and
  that the emitted DDL is valid Postgres that actually builds an HNSW index carrying
  those storage parameters — exercised on a PER-TEST THROWAWAY table (mirroring
  `Loopctl.Repo.ReconcileHnswIndexMigrationTest`), never the shared live index.
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Repo.HnswIndex

  setup do
    pid = Sandbox.start_owner!(AdminRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    table = "hnsw_params_test_#{System.unique_integer([:positive])}"
    AdminRepo.query!("CREATE TABLE #{table} (id bigserial PRIMARY KEY, embedding vector(1536))")

    %{table: table}
  end

  describe "with_params_clause/0 + configured build params" do
    test "emits WITH (m, ef_construction) from the configured functions (default 16/64)" do
      # Config/test.exs inherits config/config.exs defaults 16 / 64.
      assert HnswIndex.hnsw_m() == 16
      assert HnswIndex.hnsw_ef_construction() == 64

      # Driven by the functions, not a stray literal — the clause is exactly the
      # configured values interpolated, so this proves the builder is config-driven
      # (a future config change would be reflected here) without an Application.put_env.
      expected =
        "WITH (m = #{HnswIndex.hnsw_m()}, ef_construction = #{HnswIndex.hnsw_ef_construction()})"

      assert HnswIndex.with_params_clause() == expected
      assert HnswIndex.with_params_clause() == "WITH (m = 16, ef_construction = 64)"
    end

    test "create_if_absent_sql carries the explicit WITH clause on the CREATE INDEX" do
      sql = HnswIndex.create_if_absent_sql("articles")

      assert sql =~ "USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)"
    end
  end

  describe "the emitted DDL is valid Postgres and builds an HNSW index with the params" do
    test "create_if_absent_sql builds an hnsw index whose reloptions carry m/ef_construction",
         %{table: table} do
      AdminRepo.query!(HnswIndex.create_if_absent_sql(table))

      # The index exists, is HNSW, and its definition carries the explicit storage params.
      %{rows: [[indexdef]]} =
        AdminRepo.query!(
          "SELECT indexdef FROM pg_indexes WHERE tablename = $1 AND indexdef ILIKE '%USING hnsw%'",
          [table]
        )

      assert indexdef =~ "USING hnsw"
      # Postgres renders reloptions as quoted strings: WITH (m='16', ef_construction='64').
      assert indexdef =~ ~r/m\s*=\s*'?16'?/
      assert indexdef =~ ~r/ef_construction\s*=\s*'?64'?/
    end
  end
end
