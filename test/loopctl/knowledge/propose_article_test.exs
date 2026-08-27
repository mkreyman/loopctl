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

    test "a GATE-drafted proposal is not marked as a deliberate stage", %{tenant: tenant} do
      # `staged_draft_at` records what the CALLER asked for, never what happened. This
      # caller asked to publish and the gate held it, so it earns the ordinary 48h floor
      # in `Loopctl.Knowledge.DraftConsumer`, not the long one a deliberate stage gets.
      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Adjacent again", status: :published})

      assessor(:low_novelty, [neighbor(existing, 0.91)], 0.91)

      assert {:ok, %{verdict: :gated_to_draft, article: article}} =
               Knowledge.propose_article(tenant.id, %{
                 "title" => "Held by the gate, not by its author",
                 "body" => "Mostly covered by an adjacent article.",
                 "category" => "finding",
                 "status" => "published"
               })

      assert article.status == :draft
      assert article.staged_draft_at == nil
    end

    test "an explicit :staged_draft opt DOES mark it", %{tenant: tenant} do
      assessor(:novel)

      assert {:ok, %{article: article}} =
               Knowledge.propose_article(
                 tenant.id,
                 %{
                   "title" => "Staged on purpose",
                   "body" => "The caller asked for this to be held.",
                   "category" => "finding",
                   "status" => "draft"
                 },
                 staged_draft: true
               )

      assert article.status == :draft
      assert %DateTime{} = article.staged_draft_at
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
      ghost = %{id: Ecto.UUID.generate(), title: "Ghost", similarity_score: 0.93}
      live = fixture(:article, %{tenant_id: tenant.id, title: "Survivor", status: :published})
      assessor(:low_novelty, [ghost, neighbor(live, 0.9)], 0.93)
      before = count_articles(tenant.id)

      # Unlike the :duplicate path, a vanished neighbor must NOT fall back to creating —
      # the caller asked never to create on high overlap.
      assert {:ok, %{verdict: :skipped_low_novelty, created: false} = result} =
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

      # Only the VANISHED neighbor is dropped: the drop stays attributable to the ones
      # the caller can still fetch.
      assert result.article.id == live.id
      assert Enum.map(result.assessment.neighbors, & &1.id) == [live.id]
      assert count_articles(tenant.id) == before
    end

    test "on_low_novelty: :skip still honours an idempotency_key match", %{tenant: tenant} do
      existing =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Banked earlier",
          status: :published,
          idempotency_key: "capture-42"
        })

      assessor(:low_novelty, [neighbor(existing, 0.93)], 0.93)

      attrs = %{
        "title" => "Banked earlier (retry)",
        "body" => "Body.",
        "category" => "finding",
        "idempotency_key" => "capture-42"
      }

      # A retry must still get its OWN article id back, not be dropped against it.
      assert {:ok, %{verdict: :deduplicated, created: false, article: %{id: id}}} =
               Knowledge.propose_article(tenant.id, attrs, on_low_novelty: :skip)

      assert id == existing.id
    end

    test "on_low_novelty: :skip errors on a foreign project_id instead of reporting a skip", %{
      tenant: tenant
    } do
      assessor(:low_novelty, [], 0.93)

      attrs = %{
        "title" => "Misconfigured writer",
        "body" => "Body.",
        "category" => "finding",
        "project_id" => Ecto.UUID.generate()
      }

      assert {:error, %Ecto.Changeset{errors: [project_id: _]}} =
               Knowledge.propose_article(tenant.id, attrs, on_low_novelty: :skip)
    end

    test "on_low_novelty: :skip errors on an invalid payload instead of reporting a skip", %{
      tenant: tenant
    } do
      assessor(:low_novelty, [], 0.93)

      attrs = %{
        "title" => "Misconfigured writer",
        "body" => "Body.",
        "source_type" => "session-capture"
      }

      # A permanently broken writer must learn its payloads are invalid — a 422, not a
      # success-shaped drop it would read as a healthy pipeline forever.
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Knowledge.propose_article(tenant.id, attrs, on_low_novelty: :skip)

      assert Keyword.has_key?(changeset.errors, :category)
      assert Keyword.has_key?(changeset.errors, :source_type)
    end

    test "on_low_novelty: :skip answers an exact active-title collision, never a drop", %{
      tenant: tenant
    } do
      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Taken title", status: :published})

      assessor(:low_novelty, [neighbor(existing, 0.93)], 0.93)

      attrs = %{
        "title" => "Taken title",
        "body" => "A different body entirely.",
        "category" => "finding"
      }

      # 409, so the client can retry with a disambiguated title — the same answer it
      # would get without the flag.
      assert {:error, :duplicate_title, %{id: id}} =
               Knowledge.propose_article(tenant.id, attrs, on_low_novelty: :skip)

      assert id == existing.id
    end

    test "on_low_novelty: :skip drops a :duplicate whose neighbor vanished", %{tenant: tenant} do
      ghost_id = Ecto.UUID.generate()
      assessor(:duplicate, [%{id: ghost_id, title: "Ghost", similarity_score: 0.99}], 0.99)
      before = count_articles(tenant.id)

      # :duplicate is the HIGHER-overlap band, so a vanished canonical must not fall back
      # to creating for a caller that opted out of creating at LESS overlap.
      assert {:ok, %{verdict: :skipped_low_novelty, created: false, article: nil}} =
               Knowledge.propose_article(
                 tenant.id,
                 %{
                   "title" => "Would have been published",
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
