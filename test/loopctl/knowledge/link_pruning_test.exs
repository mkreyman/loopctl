defmodule Loopctl.Knowledge.LinkPruningTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.LinkPruning

  defp published(tenant_id, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Body.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp link(tenant_id, source, target, sim) do
    typed_link(tenant_id, source, target, sim, :relates_to)
  end

  defp typed_link(tenant_id, source, target, sim, type) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source.id,
      target_article_id: target.id,
      relationship_type: type,
      metadata: %{"auto_generated" => true, "similarity_score" => sim}
    })
  end

  defp edge_ids(tenant_id, type \\ :relates_to) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == ^type,
      select: l.id
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  defp degree(tenant_id, article) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :relates_to,
      where: l.source_article_id == ^article.id or l.target_article_id == ^article.id
    )
    |> AdminRepo.aggregate(:count)
  end

  describe "prune/2 — top-K by similarity" do
    test "drops the edges outside top-K and keeps the NEAREST ones" do
      tenant = fixture(:tenant)
      hub = published(tenant.id)
      # 6 spokes at descending similarity, all attached only to the hub. With K=2 the hub
      # keeps its 2 best; the other 4 spokes each keep their single edge (rank 1 of their
      # own partition), so union-kNN keeps all 6 — which is the property the next test
      # isolates. Here the spokes are cross-linked to give them better edges of their own,
      # so the hub's weak edges genuinely fall outside BOTH endpoints' top-K.
      spokes = for _i <- 1..6, do: published(tenant.id)

      hub_edges =
        spokes
        |> Enum.with_index()
        |> Enum.map(fn {s, i} -> {s, link(tenant.id, hub, s, 0.90 - i * 0.05)} end)

      # Give every spoke two strong mutual edges so its own top-2 is never the hub edge.
      for {s, _} <- Enum.drop(hub_edges, 2) do
        a = published(tenant.id)
        b = published(tenant.id)
        link(tenant.id, s, a, 0.99)
        link(tenant.id, s, b, 0.98)
      end

      assert {:ok, %{pruned: pruned, remaining: 0}} =
               LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      assert pruned > 0
      surviving = edge_ids(tenant.id)

      # The hub's two BEST edges survive.
      for {_s, edge} <- Enum.take(hub_edges, 2) do
        assert MapSet.member?(surviving, edge.id)
      end

      # Its four weakest do not — each spoke's own top-2 is the 0.99/0.98 pair.
      for {_s, edge} <- Enum.drop(hub_edges, 2) do
        refute MapSet.member?(surviving, edge.id)
      end
    end

    test "UNION-kNN: an edge survives on EITHER endpoint's top-K, not both" do
      # This is the guarantee that makes unattended pruning safe. Under mutual-kNN the
      # hub's weak edge would be deleted even though it is the spoke's ONLY relationship.
      tenant = fixture(:tenant)
      hub = published(tenant.id)
      strong_a = published(tenant.id)
      strong_b = published(tenant.id)
      lonely = published(tenant.id)

      link(tenant.id, hub, strong_a, 0.99)
      link(tenant.id, hub, strong_b, 0.98)
      weak = link(tenant.id, hub, lonely, 0.61)

      assert {:ok, %{pruned: 0, remaining: 0}} =
               LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      assert MapSet.member?(edge_ids(tenant.id), weak.id),
             "the hub's 3rd-best edge is the lonely article's ONLY edge — union-kNN must keep it"
    end

    test "pruning can never create an orphan" do
      # An article holding at least one edge holds it at rank 1 of its own partition, and
      # rank 1 is always inside top-K. Asserted rather than assumed because the orphan
      # re-linker would otherwise silently re-create whatever this deleted, every night.
      tenant = fixture(:tenant)
      articles = for _i <- 1..12, do: published(tenant.id)
      [hub | spokes] = articles

      for {s, i} <- Enum.with_index(spokes) do
        link(tenant.id, hub, s, 0.95 - i * 0.03)
      end

      assert {:ok, _} = LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      for a <- articles do
        assert degree(tenant.id, a) >= 1,
               "article #{a.id} was orphaned by pruning"
      end
    end
  end

  describe "prune/2 — what it refuses to touch" do
    # Each test below varies EXACTLY ONE clause of `prunable_predicate/0` away from a
    # doomed edge, so deleting that clause makes the test fail. A guarded edge that a
    # SECOND guard would also have saved proves nothing about the first — that is how all
    # three of these passed vacuously before.
    test "never deletes a potential_conflict edge" do
      # That pile has its own threshold and its own draining consumer
      # (`judge_redundant_conflicts/1`, capped above the promotion rate). Pruning it would
      # withhold pairs from a queue designed to empty itself.
      tenant = fixture(:tenant)
      hub = published(tenant.id)
      targets = for _i <- 1..3, do: published(tenant.id)

      link(tenant.id, hub, published(tenant.id), 0.92)
      link(tenant.id, hub, published(tenant.id), 0.91)

      conflicts =
        for {t, i} <- Enum.with_index(targets) do
          # Deliberately BELOW the conflict threshold. A promoted conflict link sits above
          # it and would be spared by the conflict-band guard too, so a test built from one
          # could not tell the `relationship_type` clause from that one.
          link(tenant.id, t, published(tenant.id), 0.92)
          link(tenant.id, t, published(tenant.id), 0.91)
          typed_link(tenant.id, hub, t, 0.70 - i * 0.01, :potential_conflict)
        end

      assert {:ok, _} = LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      surviving = edge_ids(tenant.id, :potential_conflict)

      for c <- conflicts do
        assert MapSet.member?(surviving, c.id)
      end
    end

    test "never deletes a hand-made relates_to link (no auto_generated flag)" do
      # A hand-made edge is not regenerable, so the whole justification for deleting rather
      # than soft-deleting does not apply to it. None exist on the corpus today; this guard
      # is what keeps that safe if one is ever added.
      tenant = fixture(:tenant)
      hub = published(tenant.id)
      strong_a = published(tenant.id)
      strong_b = published(tenant.id)
      hand_target = published(tenant.id)
      other = published(tenant.id)

      link(tenant.id, hub, strong_a, 0.92)
      link(tenant.id, hub, strong_b, 0.91)
      # Give hand_target strong edges of its own so the hand-made edge is outside BOTH
      # endpoints' top-K — the only condition under which it could be deleted.
      link(tenant.id, hand_target, other, 0.92)
      link(tenant.id, hand_target, published(tenant.id), 0.915)

      handmade =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: hub.id,
          target_article_id: hand_target.id,
          relationship_type: :relates_to,
          # Carries a SCORE but no `auto_generated` flag, so the `auto_generated` clause is
          # the only thing between it and deletion. With no score the scoreless clause would
          # have saved it too and this test would pass with the guard removed.
          metadata: %{"note" => "curated by hand", "similarity_score" => 0.61}
        })

      assert {:ok, _} = LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      assert MapSet.member?(edge_ids(tenant.id), handmade.id),
             "a link with no auto_generated flag is not regenerable and must never be pruned"
    end

    test "never deletes an edge with no similarity_score — unrankable means unprunable" do
      # The ranking sorts `DESC NULLS LAST` and the conflict band compares
      # `coalesce(sim, 0)`, so a scoreless edge ranks WORST and is not band-protected: this
      # clause is the only one holding it, and removing it deletes the edge below.
      tenant = fixture(:tenant)
      hub = published(tenant.id)
      strong_a = published(tenant.id)
      strong_b = published(tenant.id)
      scoreless_target = published(tenant.id)

      link(tenant.id, hub, strong_a, 0.92)
      link(tenant.id, hub, strong_b, 0.91)
      link(tenant.id, scoreless_target, published(tenant.id), 0.92)
      link(tenant.id, scoreless_target, published(tenant.id), 0.915)

      scoreless =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: hub.id,
          target_article_id: scoreless_target.id,
          relationship_type: :relates_to,
          metadata: %{"auto_generated" => true}
        })

      assert {:ok, _} = LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      assert MapSet.member?(edge_ids(tenant.id), scoreless.id)
    end

    test "never deletes a relates_to edge in the conflict band" do
      # `KnowledgeLintWorker.promote_conflicts/1` sources its candidates EXCLUSIVELY from
      # these rows and is capped at 500/night against a much larger backlog, and the prune
      # runs in the same nightly pass. Deleting one before the promoter reached it would
      # make that pair permanently invisible to conflict detection — a cap on the conflict
      # queue's inflow, imposed sideways.
      tenant = fixture(:tenant)
      band = Application.get_env(:loopctl, :knowledge_conflict_threshold, 0.93)
      hub = published(tenant.id)
      target = published(tenant.id)

      # Both endpoints hold two NEARER edges, so the band edge is outside both top-2s and
      # only the band guard can save it.
      link(tenant.id, hub, published(tenant.id), band + 0.05)
      link(tenant.id, hub, published(tenant.id), band + 0.04)
      link(tenant.id, target, published(tenant.id), band + 0.05)
      link(tenant.id, target, published(tenant.id), band + 0.04)

      in_band = link(tenant.id, hub, target, band)

      assert {:ok, %{remaining: 0}} =
               LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      assert MapSet.member?(edge_ids(tenant.id), in_band.id)
    end

    test "the prune is ONE statement, and it carries the predicate" do
      # The delete and the remainder count used to be two statements, so the guard could
      # drift between them and the worker would report a backlog it was structurally unable
      # to drain. They are one statement now; this is what keeps that true.
      predicate = LinkPruning.prunable_predicate()

      assert predicate =~ "relates_to"
      assert predicate =~ "auto_generated"
      assert predicate =~ "similarity_score"

      source = File.read!("lib/loopctl/knowledge/link_pruning.ex")

      interpolations =
        source
        |> String.split("WHERE tenant_id = $1 \#{prunable_predicate()}")
        |> length()
        |> Kernel.-(1)

      assert interpolations == 1,
             "expected exactly ONE SQL statement interpolating prunable_predicate/0, found " <>
               "#{interpolations}"
    end
  end

  describe "prune/2 — bounding and convergence" do
    test "respects max_per_run and reports the remainder" do
      tenant = fixture(:tenant)
      hub = published(tenant.id)

      for i <- 1..10 do
        s = published(tenant.id)
        link(tenant.id, hub, s, 0.90 - i * 0.02)
        link(tenant.id, s, published(tenant.id), 0.99)
        link(tenant.id, s, published(tenant.id), 0.98)
      end

      assert {:ok, %{pruned: 2, remaining: rest}} =
               LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 2)

      assert rest > 0, "a capped run must report what it could not reach"

      # Draining converges: run until nothing is prunable.
      final =
        Enum.reduce_while(1..20, nil, fn _i, _acc ->
          {:ok, r} = LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 2)
          if r.remaining == 0, do: {:halt, r}, else: {:cont, r}
        end)

      assert final.remaining == 0
    end

    test "is idempotent — a second run on a pruned graph deletes nothing" do
      tenant = fixture(:tenant)
      hub = published(tenant.id)

      for i <- 1..6 do
        s = published(tenant.id)
        link(tenant.id, hub, s, 0.90 - i * 0.02)
        link(tenant.id, s, published(tenant.id), 0.99)
        link(tenant.id, s, published(tenant.id), 0.98)
      end

      assert {:ok, %{remaining: 0}} =
               LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      before = edge_ids(tenant.id)

      assert {:ok, %{pruned: 0, remaining: 0}} =
               LinkPruning.prune(tenant.id, target_degree: 2, max_per_run: 1000)

      assert edge_ids(tenant.id) == before
    end
  end

  describe "tenant isolation" do
    test "pruning tenant A leaves tenant B's edges untouched" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      for tenant <- [tenant_a, tenant_b] do
        hub = published(tenant.id)

        for i <- 1..6 do
          s = published(tenant.id)
          link(tenant.id, hub, s, 0.90 - i * 0.02)
          link(tenant.id, s, published(tenant.id), 0.99)
          link(tenant.id, s, published(tenant.id), 0.98)
        end
      end

      b_before = edge_ids(tenant_b.id)

      assert {:ok, %{pruned: pruned}} =
               LinkPruning.prune(tenant_a.id, target_degree: 2, max_per_run: 1000)

      assert pruned > 0
      assert edge_ids(tenant_b.id) == b_before
    end
  end
end
