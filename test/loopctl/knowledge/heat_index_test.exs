defmodule Loopctl.Knowledge.HeatIndexTest do
  @moduledoc """
  #554 — the heat-ranked, topic-less stub index.

  The point of this surface is that it takes NO query, so its misses are uncorrelated with
  embedding similarity. That makes two properties load-bearing and worth testing directly:

    * ordering really is cumulative USAGE, not recency or relevance — otherwise it is just
      another ranked list with the same blind spots as the route it exists to complement; and
    * visibility scoping holds. An index is where a leak is easiest and least likely to be
      noticed: a stub looks innocuous, and nobody reads an index the way they read a body.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge

  setup :verify_on_exit!

  defp published_article(tenant_id, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Body text for the article.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  # `heat` is a COUNT of access events, so heat is produced by inserting N of them.
  defp heat(tenant_id, article, n) do
    for _ <- 1..n do
      fixture(:article_access_event, %{tenant_id: tenant_id, article_id: article.id})
    end

    article
  end

  describe "ordering is by cumulative usage" do
    test "the most-read article ranks first, regardless of insertion order" do
      tenant = fixture(:tenant)

      cold = published_article(tenant.id, %{title: "Cold"})
      hot = published_article(tenant.id, %{title: "Hot"})
      warm = published_article(tenant.id, %{title: "Warm"})

      heat(tenant.id, cold, 1)
      heat(tenant.id, warm, 3)
      heat(tenant.id, hot, 9)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Hot", "Warm", "Cold"]
      assert Enum.map(results, & &1.heat) == [9, 3, 1]
    end

    test "an article nobody has read does not appear at all" do
      # Heat comes from a JOIN on access events, so a never-read article has no row. Asserted
      # explicitly because "absent" and "present with heat 0" are different contracts and a
      # future change to an outer join would silently swap them.
      tenant = fixture(:tenant)
      read = published_article(tenant.id, %{title: "Read"})
      _unread = published_article(tenant.id, %{title: "Never read"})

      heat(tenant.id, read, 2)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Read"]
    end

    test ":since narrows the window; the default is all-time" do
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Old favourite"})

      old = DateTime.add(DateTime.utc_now(), -30, :day)

      for _ <- 1..5 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          accessed_at: old
        })
      end

      # All-time (the default) counts the old reads — this is what makes heat "cumulative"
      # rather than "recently popular", and it is why a long-valuable article survives a
      # quiet week.
      assert {:ok, %{results: [%{heat: 5}], meta: %{heat_window: "all_time"}}} =
               Knowledge.heat_index(tenant.id)

      # A window excludes them.
      since = DateTime.add(DateTime.utc_now(), -1, :day)
      assert {:ok, %{results: [], meta: meta}} = Knowledge.heat_index(tenant.id, since: since)
      assert meta.heat_window != "all_time"
    end
  end

  describe "visibility scoping (#163) — the leak this surface makes easy" do
    test "an agent never sees another agent's private article, even as a stub" do
      tenant = fixture(:tenant)
      mine = "agent-mine"
      theirs = "agent-theirs"

      secret =
        published_article(tenant.id, %{
          title: "Their private memory",
          metadata: %{"visibility" => "private", "agent_id" => theirs}
        })

      ours = published_article(tenant.id, %{title: "Shared"})

      # The private one is HOTTER, so if ordering were applied before scoping it would be the
      # first thing in the index.
      heat(tenant.id, secret, 50)
      heat(tenant.id, ours, 1)

      assert {:ok, %{results: results}} =
               Knowledge.heat_index(tenant.id, visibility_agent_id: mine)

      titles = Enum.map(results, & &1.title)
      assert titles == ["Shared"]
      refute "Their private memory" in titles
      # Not even the id leaks — a stub list is still an enumeration of what exists.
      refute Enum.any?(results, &(&1.id == secret.id))
    end

    test "an agent DOES see its own private article" do
      tenant = fixture(:tenant)
      mine = "agent-mine"

      own =
        published_article(tenant.id, %{
          title: "My own memory",
          metadata: %{"visibility" => "owner", "agent_id" => mine}
        })

      heat(tenant.id, own, 4)

      assert {:ok, %{results: [%{title: "My own memory"}]}} =
               Knowledge.heat_index(tenant.id, visibility_agent_id: mine)
    end

    test "a non-agent caller (nil) sees everything, as elsewhere" do
      tenant = fixture(:tenant)

      secret =
        published_article(tenant.id, %{
          title: "Private",
          metadata: %{"visibility" => "private", "agent_id" => "someone"}
        })

      heat(tenant.id, secret, 2)

      assert {:ok, %{results: [%{title: "Private"}]}} = Knowledge.heat_index(tenant.id)
    end
  end

  describe "tenant isolation (repo rule)" do
    test "tenant A never sees tenant B's articles or their heat" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      a_article = published_article(a.id, %{title: "A's article"})
      b_article = published_article(b.id, %{title: "B's article"})

      heat(a.id, a_article, 1)
      heat(b.id, b_article, 99)

      assert {:ok, %{results: results}} = Knowledge.heat_index(a.id)

      assert Enum.map(results, & &1.title) == ["A's article"]
      refute Enum.any?(results, &(&1.id == b_article.id))
    end
  end

  describe "the payload is bounded and self-describing" do
    test "top_k is clamped, so an explicit override cannot flood context" do
      tenant = fixture(:tenant)

      for i <- 1..4 do
        tenant.id |> published_article(%{title: "A#{i}"}) |> then(&heat(tenant.id, &1, i))
      end

      assert {:ok, %{results: results, meta: %{top_k: 2}}} =
               Knowledge.heat_index(tenant.id, limit: 2)

      assert length(results) == 2

      # Clamped at both ends, exactly like progressive_index/3.
      assert {:ok, %{meta: %{top_k: 1}}} = Knowledge.heat_index(tenant.id, limit: 0)
      assert {:ok, %{meta: %{top_k: 100}}} = Knowledge.heat_index(tenant.id, limit: 10_000)
    end

    test "the response says how to drill, so the payload is not just prose" do
      tenant = fixture(:tenant)
      tenant.id |> published_article() |> then(&heat(tenant.id, &1, 1))

      assert {:ok, %{meta: meta}} = Knowledge.heat_index(tenant.id)

      assert meta.drill.tool == "knowledge_get"
      assert meta.drill.parameter == "article_id"
      # The ordering basis is stated, so a reader does not mistake heat for relevance.
      assert meta.drill.note =~ "usage"
      assert is_integer(meta.char_budget)
      assert is_integer(meta.chars)
    end

    test "a summary is one line and bounded, whatever the body looks like" do
      tenant = fixture(:tenant)

      article =
        published_article(tenant.id, %{
          body:
            "First line.\n\nSecond paragraph with   irregular\twhitespace. " <>
              String.duplicate("padding ", 200)
        })

      heat(tenant.id, article, 1)

      assert {:ok, %{results: [stub]}} = Knowledge.heat_index(tenant.id)

      refute stub.summary =~ "\n"
      refute stub.summary =~ "  "
      assert String.length(stub.summary) <= 120
    end

    test ":category narrows the index" do
      tenant = fixture(:tenant)

      pattern = published_article(tenant.id, %{title: "P", category: :pattern})
      decision = published_article(tenant.id, %{title: "D", category: :decision})

      heat(tenant.id, pattern, 5)
      heat(tenant.id, decision, 5)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id, category: :decision)

      assert Enum.map(results, & &1.title) == ["D"]
    end
  end
end

defmodule Loopctl.Knowledge.HeatIndexEndpointTest do
  @moduledoc """
  #554 — the HTTP surface for the heat index.

  Covers the two things unit tests on `Knowledge.heat_index/2` cannot: that the route is
  actually wired, and that visibility scoping is derived from the CALLER'S KEY rather than
  from a caller-supplied parameter. The second matters more — a scope you can pass in is not
  a scope.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo

  setup :verify_on_exit!

  defp published(tenant_id, attrs) do
    base = %{
      title: "T#{System.unique_integer([:positive])}",
      body: "b",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp heat(tenant_id, article, n) do
    for _ <- 1..n,
        do: fixture(:article_access_event, %{tenant_id: tenant_id, article_id: article.id})

    article
  end

  test "returns heat-ranked stubs with the drill instruction", %{conn: conn} do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    hot = published(tenant.id, %{title: "Hot"})
    cold = published(tenant.id, %{title: "Cold"})
    heat(tenant.id, hot, 7)
    heat(tenant.id, cold, 1)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> get(~p"/api/v1/knowledge/heat_index")
      |> json_response(200)

    assert Enum.map(body["data"], & &1["title"]) == ["Hot", "Cold"]
    assert Enum.map(body["data"], & &1["heat"]) == [7, 1]
    # Self-describing: the payload says how to act on an id.
    assert body["meta"]["drill"]["tool"] == "knowledge_get"
    assert body["meta"]["heat_window"] == "all_time"
  end

  test "a malformed `since` is a 400, not a silent widening to all-time", %{conn: conn} do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get(~p"/api/v1/knowledge/heat_index?since=not-a-date")
    |> json_response(400)
  end

  test "visibility comes from the KEY, so another tenant's articles never appear", %{conn: conn} do
    a = fixture(:tenant)
    b = fixture(:tenant)
    {a_key, _} = fixture(:api_key, %{tenant_id: a.id, role: :agent})

    a_art = published(a.id, %{title: "A"})
    b_art = published(b.id, %{title: "B"})
    heat(a.id, a_art, 1)
    heat(b.id, b_art, 50)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{a_key}")
      |> get(~p"/api/v1/knowledge/heat_index")
      |> json_response(200)

    titles = Enum.map(body["data"], & &1["title"])
    assert titles == ["A"]
    refute "B" in titles
  end
end
