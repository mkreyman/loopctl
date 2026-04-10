defmodule Loopctl.KnowledgeAnalyticsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleAccessEvent

  defp setup_tenant_with_agent do
    tenant = fixture(:tenant)
    {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, api_key}
  end

  describe "record_access/5" do
    test "creates a single event row with given access_type" do
      {tenant, api_key} = setup_tenant_with_agent()

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published
        })

      assert :ok =
               Knowledge.record_access(
                 tenant.id,
                 article.id,
                 api_key.id,
                 "get",
                 %{"source" => "controller"}
               )

      events = AdminRepo.all(ArticleAccessEvent)
      assert length(events) == 1
      [event] = events
      assert event.tenant_id == tenant.id
      assert event.article_id == article.id
      assert event.api_key_id == api_key.id
      assert event.access_type == "get"
      assert event.metadata == %{"source" => "controller"}
      assert %DateTime{} = event.accessed_at
    end

    test "is a no-op when article_id is nil" do
      {tenant, api_key} = setup_tenant_with_agent()

      assert :ok = Knowledge.record_access(tenant.id, nil, api_key.id, "get")
      assert AdminRepo.aggregate(ArticleAccessEvent, :count, :id) == 0
    end

    test "is a no-op when api_key_id is nil" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})

      assert :ok = Knowledge.record_access(tenant.id, article.id, nil, "get")
      assert AdminRepo.aggregate(ArticleAccessEvent, :count, :id) == 0
    end

    test "never raises if article does not exist (fire-and-forget)" do
      {tenant, api_key} = setup_tenant_with_agent()
      missing_article_id = Ecto.UUID.generate()

      assert :ok =
               Knowledge.record_access(
                 tenant.id,
                 missing_article_id,
                 api_key.id,
                 "get"
               )

      # Insertion fails the FK check, but the call returns :ok regardless.
      assert AdminRepo.aggregate(ArticleAccessEvent, :count, :id) == 0
    end
  end

  describe "record_search_access/5" do
    test "inserts one event per article id with rank metadata" do
      {tenant, api_key} = setup_tenant_with_agent()

      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a3 = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert :ok =
               Knowledge.record_search_access(
                 tenant.id,
                 [a1.id, a2.id, a3.id],
                 api_key.id,
                 "ecto multi"
               )

      events =
        ArticleAccessEvent
        |> AdminRepo.all()
        |> Enum.sort_by(& &1.metadata["rank"])

      assert length(events) == 3
      assert Enum.all?(events, &(&1.access_type == "search"))
      assert Enum.all?(events, &(&1.metadata["query"] == "ecto multi"))
      assert Enum.map(events, & &1.metadata["rank"]) == [1, 2, 3]
      assert Enum.map(events, & &1.article_id) == [a1.id, a2.id, a3.id]
    end

    test "no-op for empty list of ids" do
      {tenant, api_key} = setup_tenant_with_agent()

      assert :ok = Knowledge.record_search_access(tenant.id, [], api_key.id, "anything")
      assert AdminRepo.aggregate(ArticleAccessEvent, :count, :id) == 0
    end
  end

  describe "get_article_stats/2" do
    test "returns total, unique agents, by-type and recent rows" do
      tenant = fixture(:tenant)
      {_raw, agent_a} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "a"})
      {_raw, agent_b} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "b"})

      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      :ok = Knowledge.record_access(tenant.id, article.id, agent_a.id, "get")
      :ok = Knowledge.record_access(tenant.id, article.id, agent_a.id, "search")
      :ok = Knowledge.record_access(tenant.id, article.id, agent_b.id, "context")

      stats = Knowledge.get_article_stats(tenant.id, article.id)

      assert stats.article_id == article.id
      assert stats.total_accesses == 3
      assert stats.unique_agents == 2
      assert stats.accesses_by_type == %{"get" => 1, "search" => 1, "context" => 1}
      assert is_struct(stats.last_accessed_at, DateTime)
      assert length(stats.recent_accesses) == 3
    end

    test "returns zero counts when there are no events" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      stats = Knowledge.get_article_stats(tenant.id, article.id)

      assert stats.total_accesses == 0
      assert stats.unique_agents == 0
      assert stats.accesses_by_type == %{}
      assert stats.last_accessed_at == nil
      assert stats.recent_accesses == []
    end
  end

  describe "list_top_articles/2" do
    test "orders by access count descending and respects the time window" do
      tenant = fixture(:tenant)
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      hot = fixture(:article, %{tenant_id: tenant.id, title: "Hot", status: :published})
      cold = fixture(:article, %{tenant_id: tenant.id, title: "Cold", status: :published})

      for _ <- 1..3 do
        Knowledge.record_access(tenant.id, hot.id, agent.id, "get")
      end

      Knowledge.record_access(tenant.id, cold.id, agent.id, "get")

      rows = Knowledge.list_top_articles(tenant.id, since: hours_ago(1))

      assert [%{title: "Hot", access_count: 3} = top | _] = rows
      assert top.unique_agents == 1
      titles = Enum.map(rows, & &1.title)
      assert "Cold" in titles
    end

    test "filters by access_type" do
      tenant = fixture(:tenant)
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, article.id, agent.id, "get")
      Knowledge.record_access(tenant.id, article.id, agent.id, "search")
      Knowledge.record_access(tenant.id, article.id, agent.id, "search")

      [row] = Knowledge.list_top_articles(tenant.id, since: hours_ago(1), access_type: "search")
      assert row.access_count == 2
    end

    test "ignores events older than :since" do
      tenant = fixture(:tenant)
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, article.id, agent.id, "get")

      # Backdate the event 14 days
      old = DateTime.add(DateTime.utc_now(), -14 * 86_400, :second)
      AdminRepo.update_all(ArticleAccessEvent, set: [accessed_at: old])

      rows = Knowledge.list_top_articles(tenant.id, since: hours_ago(1))
      assert rows == []
    end
  end

  describe "get_agent_usage/3" do
    test "scopes results to a single api_key" do
      tenant = fixture(:tenant)
      {_raw, agent_a} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "a"})
      {_raw, agent_b} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "b"})

      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, a1.id, agent_a.id, "get")
      Knowledge.record_access(tenant.id, a1.id, agent_a.id, "search")
      Knowledge.record_access(tenant.id, a2.id, agent_a.id, "context")
      Knowledge.record_access(tenant.id, a1.id, agent_b.id, "get")

      usage = Knowledge.get_agent_usage(tenant.id, agent_a.id, since: hours_ago(1))

      assert usage.api_key_id == agent_a.id
      assert usage.total_reads == 3
      assert usage.unique_articles == 2
      assert usage.access_by_type == %{"get" => 1, "search" => 1, "context" => 1}
      assert length(usage.top_articles) == 2
    end
  end

  describe "list_unused_articles/2" do
    test "returns published articles with zero accesses in the window" do
      tenant = fixture(:tenant)
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      used = fixture(:article, %{tenant_id: tenant.id, title: "Used", status: :published})
      _unused = fixture(:article, %{tenant_id: tenant.id, title: "Unused", status: :published})

      _draft =
        fixture(:article, %{tenant_id: tenant.id, title: "Draft Only", status: :draft})

      Knowledge.record_access(tenant.id, used.id, agent.id, "get")

      rows = Knowledge.list_unused_articles(tenant.id, days_unused: 7)
      titles = Enum.map(rows, & &1.title)

      assert "Unused" in titles
      refute "Used" in titles
      refute "Draft Only" in titles
    end

    test "an article that was accessed long ago counts as unused" do
      tenant = fixture(:tenant)
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, article.id, agent.id, "get")

      old = DateTime.add(DateTime.utc_now(), -90 * 86_400, :second)
      AdminRepo.update_all(ArticleAccessEvent, set: [accessed_at: old])

      rows = Knowledge.list_unused_articles(tenant.id, days_unused: 30)
      assert Enum.any?(rows, &(&1.article_id == article.id))
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's stats, top, agent usage, or unused" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      {_raw, agent_a} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      {_raw, agent_b} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      article_a = fixture(:article, %{tenant_id: tenant_a.id, status: :published})
      article_b = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      Knowledge.record_access(tenant_a.id, article_a.id, agent_a.id, "get")
      Knowledge.record_access(tenant_b.id, article_b.id, agent_b.id, "get")

      stats_a_from_b = Knowledge.get_article_stats(tenant_b.id, article_a.id)
      assert stats_a_from_b.total_accesses == 0

      top_a = Knowledge.list_top_articles(tenant_a.id, since: hours_ago(1))
      assert Enum.all?(top_a, &(&1.article_id == article_a.id))

      usage_b_from_a = Knowledge.get_agent_usage(tenant_a.id, agent_b.id, since: hours_ago(1))
      assert usage_b_from_a.total_reads == 0

      unused_a = Knowledge.list_unused_articles(tenant_a.id, days_unused: 30)
      refute Enum.any?(unused_a, &(&1.article_id == article_b.id))
    end
  end

  describe "integration with reads" do
    test "Knowledge.get_article/3 records a get event when api_key_id is supplied" do
      {tenant, api_key} = setup_tenant_with_agent()
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, _} = Knowledge.get_article(tenant.id, article.id, api_key_id: api_key.id)

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert event.access_type == "get"
      assert event.article_id == article.id
      assert event.api_key_id == api_key.id
    end

    test "Knowledge.search_keyword/3 records search events for results" do
      {tenant, api_key} = setup_tenant_with_agent()

      _article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Ecto Multi Pattern",
          body: "Use Ecto.Multi for atomic operations",
          status: :published
        })

      {:ok, %{results: results}} =
        Knowledge.search_keyword(tenant.id, "Ecto", api_key_id: api_key.id)

      assert results != []

      events = AdminRepo.all(ArticleAccessEvent)
      assert events != []
      assert Enum.all?(events, &(&1.access_type == "search"))
      assert Enum.all?(events, &(&1.metadata["query"] == "Ecto"))
    end

    test "Knowledge.get_context/3 records context events for returned articles" do
      {tenant, api_key} = setup_tenant_with_agent()

      _article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Context Recording",
          body: "Body about context recording for analytics integration tests.",
          status: :published
        })

      {:ok, %{results: results}} =
        Knowledge.get_context(tenant.id, "context recording", api_key_id: api_key.id)

      if results != [] do
        events = AdminRepo.all(ArticleAccessEvent)
        # Only "context" events should be present (sub-search recordings suppressed)
        assert Enum.all?(events, &(&1.access_type == "context"))
        assert events != []
      end
    end

    test "search results without api_key_id record nothing" do
      tenant = fixture(:tenant)

      _article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Anonymous Read",
          body: "Body for anonymous access test",
          status: :published
        })

      {:ok, _} = Knowledge.search_keyword(tenant.id, "Anonymous")

      assert AdminRepo.aggregate(ArticleAccessEvent, :count, :id) == 0
    end
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)
end
