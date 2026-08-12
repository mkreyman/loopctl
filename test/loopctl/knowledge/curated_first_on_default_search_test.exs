defmodule Loopctl.Knowledge.CuratedFirstOnDefaultSearchTest do
  @moduledoc """
  Epic 31 resolved the curated-vs-retrieved question, and then exposed it as a SEPARATE
  tool. Measured over 2,101 KB tool calls across this fleet's transcripts, that tool was
  called ZERO times; `knowledge_search` carried 58% of the traffic.

  The framing was the defect, not the adoption. `hybrid_search/3` is a re-rank of the pool
  `search_combined/3` already builds — not a different search — so routing to it asked every
  agent to know, per query, whether a governed answer exists. Finding that out IS the search.
  Making the corpus smarter is the app's job; the agent's job is to keep sending a query.

  So the decision now runs on the default path, and these tests pin the part that is new:
  what `search_combined/3` itself returns. `hybrid_search/3`'s own behaviour is unchanged and
  stays pinned by `knowledge_hybrid_test.exs` / `hybrid_e2e_test.exs`; both now share ONE
  implementation (`decide_curated_provenance/2`), so they cannot drift apart.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  defp direction_a, do: test_vec(1536, :primary)
  defp direction_medium, do: test_vec(1536, :near)

  defp curated_article(tenant_id, attrs) do
    article = fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))
    {:ok, marked} = Knowledge.mark_curated(tenant_id, article.id, actor_label: "user:admin")
    marked
  end

  defp set_embedding(tenant_id, article, vector) do
    {:ok, updated} = Knowledge.update_embedding(tenant_id, article.id, vector)
    updated
  end

  defp stub_embeddings_by_query(mapping) do
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
      case Map.fetch(mapping, text) do
        {:ok, vector} -> {:ok, vector}
        :error -> {:ok, List.duplicate(0.1, 1536)}
      end
    end)
  end

  setup do
    tenant = fixture(:tenant)
    Knowledge.reset_circuit_breaker(tenant.id)
    %{tenant: tenant}
  end

  describe "the recorded search_event carries the decision, so it can be measured" do
    setup %{tenant: tenant} do
      {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      %{api_key: api_key}
    end

    defp recorded_modes(tenant_id) do
      import Ecto.Query

      from(e in Loopctl.Knowledge.SearchEvent,
        where: e.tenant_id == ^tenant_id,
        select: e.mode_used
      )
      |> Loopctl.AdminRepo.all()
    end

    test "a curated win is recorded as combined_curated", %{tenant: tenant, api_key: api_key} do
      query = "measurable refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      curated =
        curated_article(tenant.id, %{
          title: "Measurable refund policy",
          body: "measurable refund policy: the governed answer"
        })

      set_embedding(tenant.id, curated, direction_a())

      {:ok, _} = Knowledge.search_combined(tenant.id, query, limit: 5, api_key_id: api_key.id)

      # This is the feedback signal. `search_events` joins to `article_access_events` to ask
      # "did the searcher open anything" — labelling the branch turns that into "did leading
      # with a governed article earn more opens than not leading with one", which is a
      # judgement made from what an agent DID, not from what a ranker scored.
      assert recorded_modes(tenant.id) == ["combined_curated"]
    end

    test "no curated winner is recorded as combined_retrieved", %{
      tenant: tenant,
      api_key: api_key
    } do
      query = "measurable uncurated topic"
      stub_embeddings_by_query(%{query => direction_a()})

      plain =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "measurable uncurated topic",
          body: "measurable uncurated topic, a plain note"
        })

      set_embedding(tenant.id, plain, direction_a())

      {:ok, _} = Knowledge.search_combined(tenant.id, query, limit: 5, api_key_id: api_key.id)

      assert recorded_modes(tenant.id) == ["combined_retrieved"]
    end
  end

  describe "search_combined/3 resolves provenance on the default path" do
    test "a governed curated article is hoisted to first, with provenance", %{tenant: tenant} do
      query = "refund policy for annual plans"
      stub_embeddings_by_query(%{query => direction_a()})

      decoy =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "refund policy chatter",
          body: "refund policy for annual plans, discussed informally"
        })

      set_embedding(tenant.id, decoy, direction_medium())

      curated =
        curated_article(tenant.id, %{
          title: "Refund policy",
          body: "refund policy for annual plans: the governed answer"
        })

      set_embedding(tenant.id, curated, direction_a())

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_combined(tenant.id, query, limit: 5)

      # The whole point: an agent that sent an ordinary query, through the ordinary tool,
      # gets the governed answer first and is TOLD that is what happened.
      assert meta.provenance == :curated
      assert meta.curated_article_id == curated.id
      assert hd(results).id == curated.id
      assert is_number(meta.confidence)
      assert decoy.id in Enum.map(results, & &1.id)
    end

    test "no curated candidate resolves :retrieved, and reorders nothing", %{tenant: tenant} do
      query = "an entirely uncurated niche topic"
      stub_embeddings_by_query(%{query => direction_a()})

      a =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "niche topic one",
          body: "an entirely uncurated niche topic, first note"
        })

      set_embedding(tenant.id, a, direction_a())

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_combined(tenant.id, query, limit: 5)

      assert meta.provenance == :retrieved
      assert meta.curated_article_id == nil
      assert a.id in Enum.map(results, & &1.id)
    end

    test "provenance is reported on a later page, but the hoist is not repeated", %{
      tenant: tenant
    } do
      query = "paged refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      for i <- 1..6 do
        filler =
          fixture(:article, %{
            tenant_id: tenant.id,
            status: :published,
            title: "paged refund policy note #{i}",
            body: "paged refund policy, filler note #{i}"
          })

        set_embedding(tenant.id, filler, direction_medium())
      end

      curated =
        curated_article(tenant.id, %{
          title: "Paged refund policy",
          body: "paged refund policy: the governed answer"
        })

      set_embedding(tenant.id, curated, direction_a())

      {:ok, %{results: page1, meta: meta1}} =
        Knowledge.search_combined(tenant.id, query, limit: 3, offset: 0)

      {:ok, %{results: page2, meta: meta2}} =
        Knowledge.search_combined(tenant.id, query, limit: 3, offset: 3)

      assert hd(page1).id == curated.id

      # The DECISION is a property of the pool, so it is reported on both pages — a caller
      # that lost it after page 1 would have to branch on page number to learn whether a
      # governed answer exists, and branching on provenance alone is the field's contract.
      assert meta1.provenance == meta2.provenance

      # The HOIST is a property of the page. Repeating it would serve the winner twice to a
      # caller paging forward.
      refute curated.id in Enum.map(page2, & &1.id)
    end
  end
end
