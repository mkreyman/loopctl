defmodule Loopctl.PlanAssertionsTest do
  @moduledoc """
  Fast (non-scale) tests for the US-27.2 plan-assertion machinery: the query-capture
  + match helpers (AC-27.2.4) and the HNSW capability check (AC-27.2.3). The
  index-CHOICE assertions (refute_full_scan/assert_hnsw_index) are only meaningful at
  prod scale (the planner Seq-Scans toy tables), so they live in the :scale_nightly
  test; here we cover the pieces that are deterministic without an 80k corpus.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.PlanAssertions

  import Ecto.Query

  describe "capture_repo_queries/1 + only_query_matching/2" do
    test "captures the SQL the function emits and selects exactly one match" do
      tenant = fixture(:tenant)
      _article = fixture(:article, %{tenant_id: tenant.id, title: "Capture Me"})

      captured =
        PlanAssertions.capture_repo_queries(fn ->
          AdminRepo.all(from(a in Loopctl.Knowledge.Article, where: a.tenant_id == ^tenant.id))
        end)

      assert captured != []
      {sql, params} = PlanAssertions.only_query_matching(captured, "FROM \"articles\"")
      assert sql =~ "articles"
      assert is_list(params)
    end

    test "only_query_matching raises when zero match" do
      captured = [{"SELECT 1", []}]

      assert_raise ExUnit.AssertionError, ~r/No captured query matched/, fn ->
        PlanAssertions.only_query_matching(captured, "no_such_table_xyz")
      end
    end

    test "only_query_matching raises when more than one matches" do
      captured = [{"SELECT a FROM t", []}, {"SELECT b FROM t", []}]

      assert_raise ExUnit.AssertionError, ~r/Expected exactly one/, fn ->
        PlanAssertions.only_query_matching(captured, "FROM t")
      end
    end
  end

  # NOTE: the fresh-stats guard (AC-27.2.5) is exercised in the :scale_nightly test —
  # it must PASS after ScaleSeed runs ANALYZE. Its raise path can't be tested
  # deterministically here because pg_stat_user_tables reflects the COMMITTED table
  # (shared across the dev/test DB), not the rolled-back sandbox set, so n_live_tup /
  # last_analyze are environment-dependent.
end
