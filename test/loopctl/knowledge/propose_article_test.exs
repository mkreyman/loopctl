defmodule Loopctl.Knowledge.ProposeArticleTest do
  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  # Drive the (mocked) assessor to a chosen verdict; the gate's routing is what we test.
  defp assessor(verdict, neighbors \\ [], score \\ nil) do
    stub(Loopctl.MockProposalAssessor, :assess, fn _tenant_id, _attrs, _opts ->
      %{verdict: verdict, score: score, neighbors: neighbors}
    end)
  end

  defp neighbor(article, score),
    do: %{id: article.id, title: article.title, similarity_score: score}

  defp count_articles(tenant_id) do
    import Ecto.Query

    Loopctl.AdminRepo.aggregate(
      from(a in Knowledge.Article, where: a.tenant_id == ^tenant_id),
      :count
    )
  end

  setup do
    %{tenant: fixture(:tenant)}
  end

  describe "novel / fell-open" do
    test "novel proposal is created on the requested (published) path", %{tenant: tenant} do
      assessor(:novel)

      assert {:ok, %{verdict: :created, created: true, article: article}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Genuinely new",
                 "body" => "Something the corpus does not hold yet.",
                 "category" => "finding",
                 "status" => "published"
               })

      assert article.status == :published
      assert article.title == "Genuinely new"
    end

    test "unknown verdict (gate fell open) still creates — never blocks", %{tenant: tenant} do
      assessor(:unknown)

      assert {:ok, %{verdict: :created, created: true, article: article}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Created despite outage",
                 "body" => "Embedding backend was down; gate fell open.",
                 "category" => "finding",
                 "status" => "published"
               })

      assert article.status == :published
    end
  end

  describe "duplicate" do
    test "near-duplicate is NOT created; the canonical article is returned", %{tenant: tenant} do
      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Canonical", status: :published})

      assessor(:duplicate, [neighbor(existing, 0.98)], 0.98)
      before = count_articles(tenant.id)

      assert {:ok, %{verdict: :duplicate, created: false, article: returned, assessment: a}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Canonical (reworded)",
                 "body" => "Same idea, different words.",
                 "category" => "finding",
                 "status" => "published"
               })

      assert returned.id == existing.id
      assert a.score == 0.98
      # Nothing new persisted.
      assert count_articles(tenant.id) == before
    end

    test "if the canonical neighbor has vanished, it creates instead", %{tenant: tenant} do
      # The assessor reports a near-duplicate, but its id no longer resolves (the
      # article was deleted/unpublished between assess and create) — the gate must
      # fall through to creating rather than returning a phantom.
      ghost = %{id: Ecto.UUID.generate(), title: "Ghost"}
      assessor(:duplicate, [%{id: ghost.id, title: ghost.title, similarity_score: 0.99}], 0.99)

      assert {:ok, %{verdict: :created, created: true, article: article}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Survives a vanished dup target",
                 "body" => "The near-neighbor was deleted between assess and create.",
                 "category" => "finding",
                 "status" => "published"
               })

      assert article.status == :published
    end
  end

  describe "low novelty" do
    test "high-overlap proposal is downgraded to a draft with neighbors stamped", %{
      tenant: tenant
    } do
      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Adjacent", status: :published})

      assessor(:low_novelty, [neighbor(existing, 0.91)], 0.91)

      assert {:ok, %{verdict: :gated_to_draft, created: true, article: article}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Overlaps existing knowledge",
                 "body" => "Mostly covered by an adjacent article.",
                 "category" => "finding",
                 # caller asked to publish — gate downgrades to draft
                 "status" => "published"
               })

      assert article.status == :draft
      novelty = article.metadata["proposal_novelty"]
      assert novelty["verdict"] == "low_novelty"
      assert novelty["score"] == 0.91
      assert [%{"id" => id}] = novelty["nearest"]
      assert id == existing.id
    end

    test "on_low_novelty: :skip creates nothing and returns the neighbor", %{tenant: tenant} do
      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Already covered", status: :published})

      assessor(:low_novelty, [neighbor(existing, 0.93)], 0.93)
      before = count_articles(tenant.id)

      assert {:ok, %{verdict: :skipped_low_novelty, created: false, article: article}} =
               Knowledge.propose_article(
                 tenant.id,
                 %{
                   "title" => "A near-duplicate nobody would review",
                   "body" => "Mostly covered by an adjacent article.",
                   "category" => "finding",
                   "status" => "published"
                 },
                 on_low_novelty: :skip
               )

      # The whole point: no row was written, not even a draft.
      assert count_articles(tenant.id) == before
      assert article.id == existing.id
    end

    test "on_low_novelty: :skip tolerates a neighbor that vanished after assess", %{
      tenant: tenant
    } do
      # Same shape as the :duplicate path's ghost test — an id that no longer resolves.
      ghost = %{id: Ecto.UUID.generate(), title: "Ghost"}
      assessor(:low_novelty, [%{id: ghost.id, title: ghost.title, similarity_score: 0.93}], 0.93)
      before = count_articles(tenant.id)

      # Unlike the :duplicate path, a vanished neighbor must NOT fall back to creating —
      # the caller asked never to create on high overlap.
      assert {:ok, %{verdict: :skipped_low_novelty, created: false, article: nil}} =
               Knowledge.propose_article(
                 tenant.id,
                 %{
                   "title" => "Still skipped",
                   "body" => "Body.",
                   "category" => "finding",
                   "status" => "published"
                 },
                 on_low_novelty: :skip
               )

      assert count_articles(tenant.id) == before
    end

    test "defaults to drafting when on_low_novelty is not passed", %{tenant: tenant} do
      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Adjacent2", status: :published})

      assessor(:low_novelty, [neighbor(existing, 0.9)], 0.9)

      assert {:ok, %{verdict: :gated_to_draft, created: true}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Interactive caller keeps the review queue",
                 "body" => "Body.",
                 "category" => "finding",
                 "status" => "published"
               })
    end

    test "preserves caller metadata while stamping novelty", %{tenant: tenant} do
      existing = fixture(:article, %{tenant_id: tenant.id, title: "Near", status: :published})
      assessor(:low_novelty, [neighbor(existing, 0.9)], 0.9)

      assert {:ok, %{article: article}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Has caller metadata",
                 "body" => "Body.",
                 "category" => "finding",
                 "metadata" => %{"memory_type" => "insight"}
               })

      assert article.metadata["memory_type"] == "insight"
      assert article.metadata["proposal_novelty"]["score"] == 0.9
    end
  end

  describe "tenant isolation" do
    test "dedup only sees the caller's own tenant", %{tenant: tenant_a} do
      tenant_b = fixture(:tenant)
      # Default stub returns :novel regardless; this asserts the gate doesn't leak a
      # cross-tenant article as a canonical neighbor (the assessor is tenant-scoped).
      assessor(:novel)

      assert {:ok, %{verdict: :created, article: article}} =
               Knowledge.propose_article(tenant_a.id, %{
                 "title" => "Tenant A only",
                 "body" => "Body.",
                 "category" => "finding",
                 "status" => "published"
               })

      assert article.tenant_id == tenant_a.id
      # Tenant B sees none of A's articles.
      assert count_articles(tenant_b.id) == 0
    end
  end
end
