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
  alias Loopctl.Audit.AuditLog
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

  describe "naming a minted hub" do
    test "a tag every member shares names the hub" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: article(tenant, ["book-named", "chris-mccord-bruce-tate-jos-valim"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      [hub] = hubs(tenant.id)
      assert hub.title == "Source: chris mccord bruce tate jos valim"
    end

    test "a POPULAR but not universal tag is refused, and the digest stands" do
      tenant = fixture(:tenant)
      # 2 of 6 carry it. Naming the source "scalability" off 33% would be a confident
      # wrong answer — the real case was a 338-article book whose top real tag covered 19.
      for _ <- 1..2, do: article(tenant, ["book-partial", "scalability"])
      for _ <- 1..4, do: article(tenant, ["book-partial"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      [hub] = hubs(tenant.id)
      assert hub.title == "Source: book partial"
      refute hub.title =~ "scalability"
    end

    test "format and structure tags never name a hub" do
      tenant = fixture(:tenant)
      # Universal, but they describe the FORMAT, not the source.
      for _ <- 1..5, do: article(tenant, ["book-formatty", "book", "reference", "pdf"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      [hub] = hubs(tenant.id)
      assert hub.title == "Source: book formatty"
    end

    test "another source's tag never names this hub" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: article(tenant, ["book-a1b2c3", "doc-deadbeef"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      titles = Enum.map(hubs(tenant.id), & &1.title)
      # Both source tags are universal here; neither may be used as the other's NAME.
      assert Enum.all?(titles, &(&1 in ["Source: book a1b2c3", "Source: doc deadbeef"]))
    end

    test "a hub minted with a digest title is retitled once a name becomes derivable" do
      tenant = fixture(:tenant)
      for _ <- 1..4, do: article(tenant, ["book-latename"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [first] = hubs(tenant.id)
      assert first.title == "Source: book latename"

      # The corpus grows a universal identifying tag (a re-tag pass, a later import).
      for _ <- 1..40, do: article(tenant, ["book-latename", "some-real-author"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [again] = hubs(tenant.id)

      assert again.id == first.id, "retitle must not mint a second hub"
      assert again.title == "Source: some real author"
    end

    test "a name is never reverted to a digest when the source grows" do
      tenant = fixture(:tenant)
      for _ <- 1..10, do: article(tenant, ["book-flip", "advanced-cypher-concepts"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id, min_siblings: 3)
      [first] = hubs(tenant.id)
      assert first.title == "Source: advanced cypher concepts"

      # Three untagged members put the naming tag under the 0.9 coverage floor, which is
      # recomputed against the CURRENT member count on every run. Weekly (#725) that
      # flips a well-named hub back to a digest and pays for a re-embedding each time,
      # then flips back when enough tagged members arrive.
      for _ <- 1..3, do: article(tenant, ["book-flip"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id, min_siblings: 3)
      [again] = hubs(tenant.id)

      assert again.id == first.id
      assert again.title == "Source: advanced cypher concepts"
    end

    test "an unattended mint is audited as the system worker, not as an API key" do
      tenant = fixture(:tenant)
      for _ <- 1..4, do: article(tenant, ["book-attributed"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id, min_siblings: 3)
      [hub] = hubs(tenant.id)

      entry =
        from(e in AuditLog,
          where: e.tenant_id == ^tenant.id,
          where: e.action == "article.created" and e.entity_id == ^hub.id
        )
        |> AdminRepo.one()

      # `Knowledge` defaults actor_type to "api_key" with a nil id, so an unattended
      # writer records every hub against an API key that does not exist.
      assert entry.actor_type == "system"
      assert entry.actor_label == "worker:structural_links"
    end

    test "a universal tag that is not name-SHAPED is refused" do
      tenant = fixture(:tenant)

      # All three sat on 100% of a real source's members and each produced a hub title
      # worse than the digest it replaced.
      for {src, junk} <- [
            {"book-frag", "2222-location-reporting-sometimes-goes-w"},
            {"book-role", "administrator"},
            {"book-trunc", "some-real-name-x"}
          ] do
        for _ <- 1..5, do: article(tenant, [src, junk])
      end

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      titles = hubs(tenant.id) |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Source: book frag", "Source: book role", "Source: book trunc"]
    end

    test "a generated title that turned out badly can be corrected later" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: article(tenant, ["book-fixme", "an-early-name"])
      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [first] = hubs(tenant.id)
      assert first.title == "Source: an early name"

      # The early name stops being universal as the source grows; a better one takes over.
      for _ <- 1..60, do: article(tenant, ["book-fixme", "the-better-name"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [again] = hubs(tenant.id)

      assert again.id == first.id
      assert again.title == "Source: the better name"
    end

    test "two sources that compute the SAME name get two hubs, never one" do
      tenant = fixture(:tenant)

      # The real case: every document in a Synology share carries `synology-netbackup`,
      # so it is universal for each of them separately. Returning the first source's hub
      # for the second merged 85 sources onto one node and 6,471 members with it.
      for _ <- 1..5, do: article(tenant, ["doc-aaa111", "synology-netbackup"])
      for _ <- 1..5, do: article(tenant, ["doc-bbb222", "synology-netbackup"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert report.hubs_created == 2, "each source gets its OWN hub"
      hub_ids = hubs(tenant.id) |> Enum.map(& &1.id) |> Enum.uniq()
      assert length(hub_ids) == 2

      # And no hub may serve members drawn from more than one source.
      edges = links(tenant.id, :derived_from)

      for hub_id <- hub_ids do
        sources =
          edges
          |> Enum.filter(&(&1.target == hub_id))
          |> Enum.map(fn e ->
            AdminRepo.get!(Article, e.source).tags
            |> Enum.find(&String.starts_with?(&1, "doc-"))
          end)
          |> Enum.uniq()

        assert length(sources) == 1, "a hub must serve exactly one source"
      end
    end

    test "the disambiguated title keeps the readable name and adds the digest" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: article(tenant, ["doc-ccc333", "shared-collection"])
      for _ <- 1..5, do: article(tenant, ["doc-ddd444", "shared-collection"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      titles = hubs(tenant.id) |> Enum.map(& &1.title) |> Enum.sort()
      assert length(Enum.uniq(titles)) == 2, "titles must be distinct"
      assert Enum.any?(titles, &(&1 == "Source: shared collection"))
      assert Enum.any?(titles, &String.contains?(&1, "shared collection ("))
    end

    test "a title that is not ours is never overwritten" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: article(tenant, ["book-handnamed", "an-author"])
      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [hub] = hubs(tenant.id)

      {:ok, _} = Knowledge.update_article(tenant.id, hub.id, %{title: "A Human Chose This"})

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)
      [after_run] = hubs(tenant.id)
      assert after_run.title == "A Human Chose This"
    end
  end

  describe "the corpus scan is paged, and paging must not change the answer" do
    test "a source spanning many pages is grouped whole" do
      tenant = fixture(:tenant)
      members = for _ <- 1..7, do: article(tenant, ["book-paged"])

      # scan_batch: 2 forces four pages over seven rows. The regression this guards is
      # silent UNDER-counting: a source split across pages that is grouped per-page would
      # look smaller than it is and could fall under the floor, producing no hub at all.
      assert {:ok, report} = StructuralLinks.harvest(tenant.id, scan_batch: 2)

      assert report.edges_created == 7
      [hub] = hubs(tenant.id)

      edges = links(tenant.id, :derived_from)
      assert MapSet.new(edges, & &1.source) == MapSet.new(members, & &1.id)
      assert Enum.all?(edges, &(&1.target == hub.id))
    end

    test "paging does not change which sources clear the floor" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: article(tenant, ["book-justover"])
      for _ <- 1..2, do: article(tenant, ["book-justunder"])

      assert {:ok, paged} = StructuralLinks.harvest(tenant.id, scan_batch: 1, min_siblings: 5)

      assert paged.hubs_created == 1, "the 5-article source clears a floor of 5"
      assert paged.sources_below_floor == 1
      assert paged.edges_created == 5
    end

    test "articles with no source are counted once, not once per page" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: article(tenant, ["book-counted"])
      for _ <- 1..4, do: article(tenant, ["no-source-here"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id, scan_batch: 2)

      assert report.articles_without_source == 4
    end
  end

  describe "the report reconciles its own arithmetic (#725)" do
    test "a clean run accounts for every source and gives each one its own hub" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: article(tenant, ["book-recon-a"])
      for _ <- 1..3, do: article(tenant, ["book-recon-b"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id, min_siblings: 3)

      assert report.sources_qualifying == 2
      assert report.distinct_hubs == 2
      assert report.hubs_created == 2
      assert report.reconciled
    end

    test "two sources sharing a hub that tags them BOTH is counted, not alarmed" do
      tenant = fixture(:tenant)

      # The live shape: 1,195 articles carry two source tags, so a `hub`-tagged one is
      # adoptable by BOTH of its sources. That is ordinary and permanent, so pinning the
      # tenant-wide verdict false on it would leave the weekly :error log always on — and
      # an alarm that never clears cannot detect the merge it exists for.
      _dual = article(tenant, ["book-dual-a", "book-dual-b", "hub"], %{title: "Two Sources"})
      for _ <- 1..3, do: article(tenant, ["book-dual-a"])
      for _ <- 1..3, do: article(tenant, ["book-dual-b"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id, min_siblings: 3)

      assert report.hubs_adopted == 2
      assert report.distinct_hubs == 1
      assert report.shared_hubs == 1

      assert report.reconciled,
             "both sources tag this hub, so its derived_from edges still mean what they " <>
               "say — reporting it as corruption is how the #724 detector goes deaf"
    end

    test "a source landing on a hub that does not carry its tag IS unreconciled" do
      tenant = fixture(:tenant)

      # The #724 merge, reduced: a hub row already answers this source's idempotency_key
      # but is tagged for a DIFFERENT source, so a `derived_from` edge to it means
      # "derived from something else". Every other count in the report stays healthy.
      article(tenant, ["book-somebody-else", "hub"], %{
        title: "Source: somebody else",
        idempotency_key: "structural-hub-book-orphan",
        metadata: %{"hub_kind" => "source", "source_key" => "book-somebody-else"}
      })

      for _ <- 1..3, do: article(tenant, ["book-orphan"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id, min_siblings: 3)

      assert report.hubs_resolved == 1
      assert report.hubs_unattributed == 1
      assert report.shared_hubs == 0

      refute report.reconciled,
             "attribution is the whole verdict — delete count_attribution/3 and this is " <>
               "the test that must fail"
    end
  end

  describe "adopting the hub the extraction pipeline already made" do
    test "an existing hub-tagged sibling becomes the star centre, and nothing is minted" do
      tenant = fixture(:tenant)

      # This is the real corpus shape: every extraction skill emits "hub + atomic notes",
      # so the source already has a hub carrying its actual NAME. Minting beside it would
      # put "Source: book 6a3020c2cd15" next to "Advanced Cypher Concepts".
      existing =
        article(tenant, ["book-adopt", "hub"], %{title: "Advanced Cypher Concepts"})

      members = for _ <- 1..3, do: article(tenant, ["book-adopt"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert report.hubs_adopted == 1
      assert report.hubs_created == 0
      assert hubs(tenant.id) == [], "no synthetic hub_kind article should exist"

      edges = links(tenant.id, :derived_from)
      assert Enum.all?(edges, &(&1.target == existing.id))
      assert length(edges) == 3
      assert MapSet.new(edges, & &1.source) == MapSet.new(members, & &1.id)
    end

    test "the adopted hub is never linked to itself" do
      tenant = fixture(:tenant)
      existing = article(tenant, ["book-adopt2", "hub"], %{title: "Real Title"})
      for _ <- 1..3, do: article(tenant, ["book-adopt2"])

      assert {:ok, _} = StructuralLinks.harvest(tenant.id)

      refute Enum.any?(links(tenant.id, :derived_from), &(&1.source == existing.id))
    end

    test "adoption is idempotent and picks the same hub on a re-run" do
      tenant = fixture(:tenant)
      existing = article(tenant, ["book-adopt3", "hub"], %{title: "Stable"})
      for _ <- 1..3, do: article(tenant, ["book-adopt3"])

      assert {:ok, first} = StructuralLinks.harvest(tenant.id)
      assert {:ok, second} = StructuralLinks.harvest(tenant.id)

      assert first.edges_created == 3
      assert second.edges_created == 0
      assert second.hubs_adopted == 1

      assert Enum.all?(links(tenant.id, :derived_from), &(&1.target == existing.id))
    end

    test "a source with no existing hub still mints one" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: article(tenant, ["book-nohub"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert report.hubs_created == 1
      assert report.hubs_adopted == 0
      assert [_minted] = hubs(tenant.id)
    end

    test "a hub tag belonging to a DIFFERENT source is not adopted" do
      tenant = fixture(:tenant)
      # A hub for another book must not become this book's centre just by carrying "hub".
      article(tenant, ["book-other", "hub"], %{title: "Someone Else's Book"})
      for _ <- 1..3, do: article(tenant, ["book-mine"])

      assert {:ok, report} = StructuralLinks.harvest(tenant.id)

      assert report.hubs_created == 1, "book-mine had no hub of its own, so one is minted"
      [minted] = hubs(tenant.id)
      assert Enum.all?(links(tenant.id, :derived_from), &(&1.target == minted.id))
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
