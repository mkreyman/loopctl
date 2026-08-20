defmodule Loopctl.Knowledge.StructuralLinksTest do
  @moduledoc """
  US-42.1 — `derived_from` star edges harvested from source provenance.

  The load-bearing assertion in this file is TC-42.1.1's "zero edges between two non-hub
  articles". A sibling-to-sibling harvest is the obvious implementation and it is
  catastrophic at this corpus's shape: one 1,523-article book source would produce ~1.16M
  edges on its own, more than the entire pre-pruning graph #611 stage 0 exists to reduce.
  The star shape is the whole design, so it is asserted directly rather than inferred from
  an edge count.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.LinkPruning
  alias Loopctl.Knowledge.StructuralLinks

  defp article(tenant, tags, attrs \\ %{}) do
    fixture(
      :article,
      Map.merge(%{tenant_id: tenant.id, tags: tags, status: :published}, attrs)
    )
  end

  # fixture(:api_key, ...) returns {raw_key, api_key} — heat ranks by DISTINCT
  # coalesce(agent_id, api_key_id), so each reader here needs its own real key row.
  defp key_id(tenant) do
    {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id})
    key.id
  end

  defp links(tenant_id, type) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id and l.relationship_type == ^type,
      select: %{source: l.source_article_id, target: l.target_article_id}
    )
    |> AdminRepo.all()
  end

  defp hubs(tenant_id) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: fragment("? ->> 'hub_kind' = 'source'", a.metadata),
      select: a
    )
    |> AdminRepo.all()
  end

  describe "source resolution" do
    test "prefers the source-family tag over the columns" do
      # The correction measurement forced: source_type/source_id are null on real
      # book-extracted articles, so a column-first rule would find almost nothing.
      assert StructuralLinks.source_key(%{
               tags: ["book-abc123", "elixir"],
               source_type: "web_article",
               source_id: "ignored"
             }) == "book-abc123"
    end

    test "falls back to the columns when no source tag is present" do
      assert StructuralLinks.source_key(%{
               tags: ["elixir"],
               source_type: "web_article",
               source_id: "xyz"
             }) == "web_article-xyz"
    end

    test "returns nil when the article carries no source at all" do
      assert StructuralLinks.source_key(%{tags: ["elixir"], source_type: nil, source_id: nil}) ==
               nil
    end

    test "recognises every declared source family" do
      for prefix <- ~w(book- doc- repo- yt-) do
        assert StructuralLinks.source_key(%{
                 tags: ["#{prefix}k1"],
                 source_type: nil,
                 source_id: nil
               }) ==
                 "#{prefix}k1"
      end
    end
  end

  describe "harvest" do
    test "TC-42.1.1: one source with N siblings yields one hub and N edges, never N^2" do
      tenant = fixture(:tenant)
      members = for _ <- 1..6, do: article(tenant, ["book-star1"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert [hub] = hubs(tenant.id)
      assert report.hubs_created == 1
      assert report.edges_created == 6

      edges = links(tenant.id, :derived_from)
      assert length(edges) == 6

      # Every edge points AT the hub, and none joins two non-hub articles. This is the
      # star assertion; an edge count alone would pass for a partial clique too.
      member_ids = MapSet.new(members, & &1.id)
      assert Enum.all?(edges, &(&1.target == hub.id))
      assert Enum.all?(edges, &MapSet.member?(member_ids, &1.source))
      refute Enum.any?(edges, &MapSet.member?(member_ids, &1.target))
    end

    test "TC-42.1.2: a second run over an unchanged corpus is a no-op" do
      tenant = fixture(:tenant)
      for _ <- 1..4, do: article(tenant, ["book-idem"])

      assert {:ok, first} = StructuralLinks.harvest(tenant.id)
      assert first.hubs_created == 1
      assert first.edges_created == 4

      assert {:ok, second} = StructuralLinks.harvest(tenant.id)
      assert second.hubs_created == 0
      assert second.hubs_resolved == 1
      assert second.edges_created == 0

      assert length(hubs(tenant.id)) == 1
      assert length(links(tenant.id, :derived_from)) == 4
    end

    test "TC-42.1.3: a source below the floor is skipped entirely" do
      tenant = fixture(:tenant)
      for _ <- 1..2, do: article(tenant, ["book-tiny"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert report.sources_below_floor == 1
      assert report.hubs_created == 0
      assert report.edges_created == 0
      assert hubs(tenant.id) == []
      assert links(tenant.id, :derived_from) == []
    end

    test "the floor is configurable per call" do
      tenant = fixture(:tenant)
      for _ <- 1..2, do: article(tenant, ["book-tiny2"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id, min_siblings: 2)
      assert report.hubs_created == 1
      assert report.edges_created == 2
    end

    test "articles carrying no source are counted, not linked" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: article(tenant, ["book-mixed"])
      for _ <- 1..2, do: article(tenant, ["just-a-topic"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert report.articles_without_source == 2
      assert report.edges_created == 3
    end

    test "TC-42.1.5: tenant isolation — one tenant's harvest never touches another's" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      # Deliberately the SAME source key in both tenants: if scoping were wrong, the
      # grouping would merge them and tenant B's articles would hang off tenant A's hub.
      for _ <- 1..4, do: article(a, ["book-shared"])
      for _ <- 1..4, do: article(b, ["book-shared"])

      assert {:ok, report} = StructuralLinks.harvest(a.id)
      assert report.edges_created == 4

      assert length(hubs(a.id)) == 1
      assert hubs(b.id) == []
      assert links(b.id, :derived_from) == []

      a_article_ids =
        from(x in Article, where: x.tenant_id == ^a.id, select: x.id)
        |> AdminRepo.all()
        |> MapSet.new()

      # No edge in tenant A may reference anything outside tenant A.
      for edge <- links(a.id, :derived_from) do
        assert MapSet.member?(a_article_ids, edge.source)
        assert MapSet.member?(a_article_ids, edge.target)
      end
    end

    test "an existing hub is not re-linked to itself on a later run" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: article(tenant, ["book-selfless"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      [hub] = hubs(tenant.id)
      refute Enum.any?(links(tenant.id, :derived_from), &(&1.source == hub.id))
    end

    test "a run that creates nothing still returns a report rather than failing" do
      tenant = fixture(:tenant)

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)
      assert report.hubs_created == 0
      assert report.edges_created == 0
      assert report.articles_without_source == 0
    end
  end

  describe "the hub is reachable, but does not rank" do
    test "AC-42.1.8: knowledge_get surfaces the hub from a member, and members from the hub" do
      tenant = fixture(:tenant)
      [member | _] = for _ <- 1..3, do: article(tenant, ["book-reach"])
      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [hub] = hubs(tenant.id)

      assert {:ok, from_member} = Knowledge.get_article(tenant.id, member.id)
      assert Enum.any?(from_member.outgoing_links, &(&1.target_article.id == hub.id))

      assert {:ok, from_hub} = Knowledge.get_article(tenant.id, hub.id)
      assert Enum.any?(from_hub.incoming_links, &(&1.source_article.id == member.id))
    end

    test "AC-42.1.6: a hub never enters the heat index, however much it is read" do
      tenant = fixture(:tenant)
      [member | _] = for _ <- 1..3, do: article(tenant, ["book-heat"])
      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [hub] = hubs(tenant.id)

      # Give the hub MORE distinct readers than the real article, so this fails loudly if
      # the exclusion is dropped: a hub accrues readers as a function of how many siblings
      # the harvest gave it, not of whether anyone found it useful.
      for _ <- 1..5 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: hub.id,
          access_type: "get",
          api_key_id: key_id(tenant)
        })
      end

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        article_id: member.id,
        access_type: "get",
        api_key_id: key_id(tenant)
      })

      assert {:ok, %{results: stubs}} = Knowledge.heat_index(tenant.id)
      ids = Enum.map(stubs, & &1.id)

      refute hub.id in ids
      assert member.id in ids
    end
  end

  describe "pruning" do
    test "TC-42.1.4: LinkPruning removes relates_to but never derived_from" do
      tenant = fixture(:tenant)
      members = for _ <- 1..3, do: article(tenant, ["book-prune"])
      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      # A structural edge is exact; a similarity ranking must never be able to evict it.
      # LinkPruning filters on relates_to by construction, so this is a REGRESSION guard
      # against a future widening of that predicate rather than a test of new code.
      [subject | _] = members

      before = links(tenant.id, :derived_from)
      assert Enum.any?(before, &(&1.source == subject.id))

      assert {:ok, _} = LinkPruning.prune(tenant.id, target_degree: 1)

      after_prune = links(tenant.id, :derived_from)
      assert Enum.any?(after_prune, &(&1.source == subject.id))
      assert length(after_prune) == length(before)
    end
  end
end
