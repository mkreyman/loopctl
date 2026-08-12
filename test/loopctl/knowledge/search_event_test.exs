defmodule Loopctl.Knowledge.SearchEventTest do
  @moduledoc """
  #658 — one row per search ATTEMPT, including the attempts that surface nothing.

  The defect these pin is not hypothetical. `maybe_record_search_access/5` returned `:ok`
  early on `results in [nil, []]`, so a search that found nothing wrote no row anywhere.
  The population that tells you the corpus or the query needs work was the exact population
  the schema could not represent, and recovering it required hand-mining 6,457 session
  transcripts across two machines.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.SearchEvent

  setup :verify_on_exit!

  describe "outcome derivation" do
    test "a search that matched nothing is zero_results, not ok" do
      assert SearchEvent.derive_outcome(%{result_count: 0}) == "zero_results"
    end

    test "DEGRADATION OUTRANKS EMPTINESS — an empty degraded search is not a corpus gap" do
      # This ordering is the point. An embedding timeout that returns no results is a
      # PROVIDER failure; filing it as zero_results reads as "the KB has nothing" and sends
      # the next investigation after the wrong thing entirely.
      assert SearchEvent.derive_outcome(%{result_count: 0, degraded?: true}) == "degraded"
    end

    test "a rejected call outranks everything — it never ran" do
      assert SearchEvent.derive_outcome(%{rejected?: true, result_count: 0, degraded?: true}) ==
               "rejected"
    end

    test "results on the requested path are ok" do
      assert SearchEvent.derive_outcome(%{result_count: 5}) == "ok"
    end
  end

  describe "term_count/1 — query shape without re-parsing" do
    test "counts whitespace-separated terms" do
      assert SearchEvent.term_count("elixir") == 1
      assert SearchEvent.term_count("custody halt tenant threshold") == 4
      assert SearchEvent.term_count("  spaced   out  words ") == 3
    end

    test "no query and a one-word query stay distinguishable — different defects" do
      assert SearchEvent.term_count(nil) == nil
      assert SearchEvent.term_count("   ") == nil
      assert SearchEvent.term_count("elixir") == 1
    end
  end

  describe "changeset" do
    test "tenant_id is NOT castable — it is set programmatically (RLS rule 4)" do
      other = Ecto.UUID.generate()

      cs =
        SearchEvent.changeset(%SearchEvent{tenant_id: "keep-me"}, %{
          outcome: "ok",
          tenant_id: other
        })

      refute Ecto.Changeset.get_change(cs, :tenant_id)
    end

    test "rejects an unknown outcome rather than storing a value nothing can query" do
      cs = SearchEvent.changeset(%SearchEvent{}, %{outcome: "sort-of-worked"})
      refute cs.valid?
    end

    test "a negative result_count is rejected" do
      cs = SearchEvent.changeset(%SearchEvent{}, %{outcome: "ok", result_count: -1})
      refute cs.valid?
    end
  end

  describe "recording a real search" do
    setup do
      tenant = fixture(:tenant)
      {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      %{tenant: tenant, api_key: api_key}
    end

    test "a search that finds NOTHING is recorded — the whole point", %{
      tenant: tenant,
      api_key: api_key
    } do
      unmatchable = "zzzz#{System.unique_integer([:positive])}qqqq"

      {:ok, %{results: results}} =
        Knowledge.search_keyword(tenant.id, unmatchable, limit: 5, api_key_id: api_key.id)

      assert results == []

      [event] = all_search_events(tenant.id)
      assert event.outcome == "zero_results"
      assert event.result_count == 0
      assert event.query == unmatchable
      assert event.tenant_id == tenant.id, "tenant_id identifies WHICH knowledge base"
      assert event.api_key_id == api_key.id
      assert event.query_terms == 1
    end

    test "a search that finds something records the attempt AND correlates to its results",
         %{tenant: tenant, api_key: api_key} do
      marker = "srchevt#{System.unique_integer([:positive])}"

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "#{marker} pattern",
          body: "The #{marker} pattern.",
          status: :published
        })

      {:ok, _} = Knowledge.search_keyword(tenant.id, marker, limit: 5, api_key_id: api_key.id)

      [event] = all_search_events(tenant.id)
      assert event.outcome == "ok"
      assert event.result_count >= 1
      assert event.top_result_id == article.id
      assert event.search_id, "a search_id is needed to join to the per-result rows"
    end

    test "the filters are captured, so a zero-result row is interpretable", %{
      tenant: tenant,
      api_key: api_key
    } do
      {:ok, _} =
        Knowledge.search_keyword(tenant.id, "anything",
          limit: 3,
          api_key_id: api_key.id,
          category: :decision
        )

      [event] = all_search_events(tenant.id)
      # Without this, a search scoped to an empty category is indistinguishable from an
      # unscoped search against a corpus that genuinely lacks the answer.
      assert event.filters["category"] == "decision"
      assert event.limit_requested == 3
    end

    test "tenant isolation: tenant B cannot see tenant A's search events", %{tenant: tenant_a} do
      tenant_b = fixture(:tenant)
      {_raw, key_b} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      {:ok, _} =
        Knowledge.search_keyword(tenant_b.id, "isolation probe", limit: 3, api_key_id: key_b.id)

      assert all_search_events(tenant_a.id) == []
      assert length(all_search_events(tenant_b.id)) == 1
    end
  end

  defp all_search_events(tenant_id) do
    import Ecto.Query

    from(e in SearchEvent, where: e.tenant_id == ^tenant_id, order_by: e.inserted_at)
    |> Loopctl.AdminRepo.all()
  end
end
