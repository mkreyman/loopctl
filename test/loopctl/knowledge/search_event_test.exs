defmodule Loopctl.Knowledge.SearchEventTest do
  @moduledoc """
  #658 — one row per search ATTEMPT, including the attempts that surface nothing.

  The defect these pin is not hypothetical. `maybe_record_search_access/5` returned `:ok`
  early on `results in [nil, []]`, so a search that found nothing wrote no row anywhere.
  The population that tells you the corpus or the query needs work was the exact population
  the schema could not represent, and recovering it required hand-mining 6,457 session
  transcripts across two machines.
  """
  use LoopctlWeb.ConnCase, async: true

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

  describe "rejected calls — the population that never reaches the search path" do
    setup do
      tenant = fixture(:tenant)
      {raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      %{tenant: tenant, api_key: api_key, raw: raw}
    end

    test "a call refused for a missing query IS recorded", %{tenant: tenant, raw: raw} do
      # The whole reason this table exists. A 400 never reaches maybe_record_search_access,
      # so without wiring the controller the `rejected` outcome is dead code and the
      # population the migration promises to capture stays invisible.
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> Phoenix.ConnTest.get(~p"/api/v1/knowledge/search")

      assert conn.status == 400

      [event] = all_search_events(tenant.id)
      assert event.outcome == "rejected"
      assert event.rejection_reason == "missing_query"
      assert event.result_count == 0
      assert event.tenant_id == tenant.id
    end

    test "the reason is a STABLE tag, not the human-facing prose", %{tenant: tenant, raw: raw} do
      # A metric keyed on the message text silently splits into two series the day the
      # wording changes.
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> Phoenix.ConnTest.get(~p"/api/v1/knowledge/search")

      [event] = all_search_events(tenant.id)
      refute event.rejection_reason =~ " "
      assert event.rejection_reason in ["missing_query", "bad_request", "invalid_cursor"]
    end
  end

  describe "the facts that make a miss interpretable" do
    setup do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      %{tenant: tenant, api_key: api_key, raw: raw}
    end

    test "a DEGRADED search is degraded — end to end, not just in derive_outcome/1", %{
      tenant: tenant,
      raw: raw
    } do
      # The guard was vacuous: nothing threaded the degradation to the recorder, so a
      # provider outage was written as `zero_results` and read as a corpus gap.
      Knowledge.reset_circuit_breaker(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant, _text ->
        {:error, :no_api_key}
      end)

      search(raw, %{q: "chain of custody lineage", mode: "semantic"})

      [event] = all_search_events(tenant.id)
      assert event.degraded == true
      assert event.fallback_reason == "no_embedding_key"
      assert event.outcome == "degraded"
      # An explicit semantic search must not file its query under "no query" (enumeration).
      assert event.query == "chain of custody lineage"
      assert event.query_terms == 4
      assert event.mode_requested == "semantic"
    end

    test "a SUCCESSFUL search carries the agent, the client context and the pool it chose from",
         %{tenant: tenant, api_key: api_key, raw: raw} do
      ctx =
        Base.encode64(
          JSON.encode!(%{"session_id" => "sess-1", "kind" => "child", "repo" => "owner/repo"})
        )

      search(raw, %{q: "anything", mode: "keyword"}, [{"x-loopctl-client-context", ctx}])

      [event] = all_search_events(tenant.id)
      # Recorded only for REJECTIONS, agent_id read as "this agent only ever fails".
      assert event.agent_id == api_key.agent_id
      refute is_nil(event.agent_id)
      assert event.client_session_id == "sess-1"
      assert event.client_kind == "child"
      assert event.client_repo == "owner/repo"
      assert event.tool == "knowledge_search"
      assert is_integer(event.total_count)
      assert is_integer(event.duration_ms)
    end

    test "an enumeration is not filed as a search", %{tenant: tenant, raw: raw} do
      search(raw, %{tags: "pagination"})

      [event] = all_search_events(tenant.id)
      assert event.tool == "knowledge_list"
      assert event.query_terms == nil
      assert is_integer(event.total_count)
    end

    test "a rejection raised INSIDE the pipeline is recorded too", %{tenant: tenant, raw: raw} do
      # A `with ... else` sees only its own conditions: the cursor rejections returned from
      # the body bypassed the recorder entirely, and `invalid_cursor` was unreachable.
      conn = search(raw, %{tags: "pagination", cursor: "not-a-real-cursor"})

      assert conn.status == 400
      [event] = all_search_events(tenant.id)
      assert event.outcome == "rejected"
      assert event.rejection_reason == "invalid_cursor"
    end
  end

  defp search(raw, params, headers \\ []) do
    Enum.reduce(
      [{"authorization", "Bearer #{raw}"} | headers],
      Phoenix.ConnTest.build_conn(),
      fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end
    )
    |> Phoenix.ConnTest.get(~p"/api/v1/knowledge/search", params)
  end

  defp all_search_events(tenant_id) do
    import Ecto.Query

    from(e in SearchEvent, where: e.tenant_id == ^tenant_id, order_by: e.inserted_at)
    |> Loopctl.AdminRepo.all()
  end
end
