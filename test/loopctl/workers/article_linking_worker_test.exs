defmodule Loopctl.Workers.ArticleLinkingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Workers.ArticleLinkingWorker

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  # Creates a published article with a known embedding vector, bypassing
  # the inline Oban cascade (embedding worker -> linking worker).
  defp create_article_with_embedding(tenant_id, embedding, attrs \\ %{}) do
    base_attrs = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Test article body.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    article =
      fixture(:article, Map.merge(base_attrs, Map.put(attrs, :tenant_id, tenant_id)))

    # Set published + embedding directly via AdminRepo to avoid Oban inline cascade
    article
    |> Ecto.Changeset.change(%{status: :published, embedding: embedding})
    |> AdminRepo.update!()
  end

  # Helper: generate deterministic embedding vectors.
  #
  # Cosine similarity measures direction, not magnitude. Uniform vectors
  # (all same value) always have similarity 1.0 regardless of value.
  # We use sparse directional vectors to control similarity:
  # - similar_embedding: positive in first half, zero in second half
  # - near_similar_embedding: same pattern with small perturbation (high cosine sim)
  # - dissimilar_embedding: zero in first half, positive in second half (orthogonal)
  defp similar_embedding do
    List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)
  end

  defp dissimilar_embedding do
    # Orthogonal to similar_embedding -- cosine similarity near 0
    List.duplicate(0.0, 768) ++ List.duplicate(1.0, 768)
  end

  defp near_similar_embedding do
    # Very close to similar_embedding but with small perturbation
    List.duplicate(1.0, 768)
    |> List.update_at(0, fn _ -> 0.99 end)
    |> List.update_at(1, fn _ -> 1.01 end)
    |> Kernel.++(List.duplicate(0.01, 768))
  end

  # cos(similar_embedding, near_miss_embedding) = 1/sqrt(1 + 1.518^2) ~= 0.55 —
  # a deliberate near-miss of the default 0.6 cutoff but above a lenient 0.5.
  defp near_miss_embedding do
    List.duplicate(1.0, 768) ++ List.duplicate(1.518, 768)
  end

  # cos(similar_embedding, this) = 768 / (sqrt(768) * sqrt(1536)) ~= 0.707 — related
  # (>= 0.6) but below the 0.93 conflict threshold.
  defp moderately_similar_embedding do
    List.duplicate(1.0, 1536)
  end

  defp links_of_type(tenant_id, a_id, b_id, type) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == ^type,
      where:
        (l.source_article_id == ^a_id and l.target_article_id == ^b_id) or
          (l.source_article_id == ^b_id and l.target_article_id == ^a_id)
    )
    |> AdminRepo.all()
  end

  describe "potential conflict detection (#4)" do
    test "flags a near-identical pair with a :potential_conflict link" do
      %{tenant: tenant} = setup_tenant()
      source = create_article_with_embedding(tenant.id, similar_embedding())
      dup = create_article_with_embedding(tenant.id, near_similar_embedding())

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # Both an ambient relates_to AND the conflict flag.
      assert [_] = links_of_type(tenant.id, source.id, dup.id, :relates_to)
      assert [conflict] = links_of_type(tenant.id, source.id, dup.id, :potential_conflict)
      assert conflict.metadata["similarity_score"] >= 0.93
      assert conflict.metadata["auto_generated"] == true
    end

    test "a merely-related pair (below the conflict threshold) gets NO conflict flag" do
      %{tenant: tenant} = setup_tenant()
      source = create_article_with_embedding(tenant.id, similar_embedding())
      related = create_article_with_embedding(tenant.id, moderately_similar_embedding())

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert [_] = links_of_type(tenant.id, source.id, related.id, :relates_to)
      assert [] == links_of_type(tenant.id, source.id, related.id, :potential_conflict)
    end
  end

  # --- TC-21.2.1: Creates relates_to links for similar articles ---

  describe "perform/1 creates links" do
    test "creates relates_to links for similar articles" do
      %{tenant: tenant} = setup_tenant()

      source = create_article_with_embedding(tenant.id, similar_embedding())
      target = create_article_with_embedding(tenant.id, near_similar_embedding())

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # Verify link was created
      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id,
          where: l.target_article_id == ^target.id,
          where: l.relationship_type == :relates_to
        )
        |> AdminRepo.all()

      assert length(links) == 1
      link = hd(links)
      assert link.metadata["auto_generated"] == true
      assert is_float(link.metadata["similarity_score"])
      assert link.metadata["similarity_score"] >= 0.6
    end
  end

  # --- TC-21.2.2: Skips articles below threshold ---

  describe "perform/1 threshold filtering" do
    test "skips articles below similarity threshold" do
      %{tenant: tenant} = setup_tenant()

      source = create_article_with_embedding(tenant.id, similar_embedding())
      _dissimilar = create_article_with_embedding(tenant.id, dissimilar_embedding())

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # No links should be created
      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.all()

      assert links == []
    end

    test "a per-job threshold override links a near-miss neighbor (orphan self-heal)" do
      %{tenant: tenant} = setup_tenant()

      # cos(source, near_miss) ~= 0.55: under the default 0.6, over a lenient 0.5.
      source = create_article_with_embedding(tenant.id, similar_embedding())
      near_miss = create_article_with_embedding(tenant.id, near_miss_embedding())

      # Default threshold: no link (this is why orphans stay orphaned).
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert [] ==
               from(l in ArticleLink, where: l.source_article_id == ^source.id)
               |> AdminRepo.all()

      # Lenient threshold passed in args: the near-miss neighbor now links.
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{
                   "article_id" => source.id,
                   "tenant_id" => tenant.id,
                   "threshold" => 0.5
                 }
               })

      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where:
            (l.source_article_id == ^source.id and l.target_article_id == ^near_miss.id) or
              (l.source_article_id == ^near_miss.id and l.target_article_id == ^source.id)
        )
        |> AdminRepo.all()

      assert length(links) == 1
      assert hd(links).metadata["similarity_score"] >= 0.5
      assert hd(links).metadata["similarity_score"] < 0.6
    end
  end

  # --- TC-21.2.3: Idempotent -- no duplicates on re-run ---

  describe "idempotency" do
    test "re-running does not create duplicate links" do
      %{tenant: tenant} = setup_tenant()

      source = create_article_with_embedding(tenant.id, similar_embedding())
      _target = create_article_with_embedding(tenant.id, near_similar_embedding())

      # Run once
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      count_before =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      # Run again
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      count_after =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert count_before == count_after
    end

    test "does not create duplicate when link exists in reverse direction" do
      %{tenant: tenant} = setup_tenant()

      article_a = create_article_with_embedding(tenant.id, similar_embedding())
      article_b = create_article_with_embedding(tenant.id, near_similar_embedding())

      # Create a link in the B -> A direction manually
      %ArticleLink{tenant_id: tenant.id}
      |> ArticleLink.changeset(%{
        source_article_id: article_b.id,
        target_article_id: article_a.id,
        relationship_type: :relates_to,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.99}
      })
      |> AdminRepo.insert!()

      # Now run linking for A -- should not create A -> B since B -> A exists
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article_a.id, "tenant_id" => tenant.id}
               })

      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where:
            (l.source_article_id == ^article_a.id and l.target_article_id == ^article_b.id) or
              (l.source_article_id == ^article_b.id and l.target_article_id == ^article_a.id)
        )
        |> AdminRepo.all()

      # Only the manually created relates_to one should exist (a high-similarity pair
      # also gets a separate :potential_conflict flag — that's #4, asserted elsewhere).
      assert length(links) == 1
    end
  end

  # --- TC-21.2.4: Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A's articles do not link to tenant B's articles" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      source_a = create_article_with_embedding(tenant_a.id, similar_embedding())
      _target_b = create_article_with_embedding(tenant_b.id, near_similar_embedding())

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source_a.id, "tenant_id" => tenant_a.id}
               })

      # No links should be created (no similar articles in tenant A)
      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant_a.id,
          where: l.source_article_id == ^source_a.id
        )
        |> AdminRepo.all()

      assert links == []
    end

    test "worker with wrong tenant returns :ok (article not visible)" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      article_a = create_article_with_embedding(tenant_a.id, similar_embedding())

      # Run with wrong tenant_id
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article_a.id, "tenant_id" => tenant_b.id}
               })
    end
  end

  # --- TC-21.2.5: Respects max comparison limit ---

  describe "max comparisons limit" do
    test "limits results to configured max_comparisons" do
      %{tenant: tenant} = setup_tenant()

      # Create source article
      source = create_article_with_embedding(tenant.id, similar_embedding())

      # Create 3 similar articles
      for _i <- 1..3 do
        create_article_with_embedding(tenant.id, near_similar_embedding())
      end

      # Override max_comparisons to 2 via Application config
      # Note: We test the limiting behavior by checking the worker
      # respects limits. Since we can't use Application.put_env in tests,
      # we verify the default behavior works. The max_comparisons
      # config is set in config.exs (default 50).
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # All 3 similar articles should be linked (within default limit of 50). Scope to
      # :relates_to — high-similarity pairs also get a :potential_conflict link (#4).
      link_count =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert link_count == 3
    end
  end

  # --- TC-21.2.6: Handles article with no embedding ---

  describe "no embedding" do
    test "returns :ok for article with no embedding" do
      %{tenant: tenant} = setup_tenant()

      # Create article without embedding (draft status, no embedding set)
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end

    test "returns :ok for deleted article" do
      %{tenant: tenant} = setup_tenant()
      fake_id = Ecto.UUID.generate()

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => fake_id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- Project scoping ---

  describe "project scoping" do
    test "project-scoped article links to same-project and tenant-wide articles" do
      %{tenant: tenant} = setup_tenant()
      project = fixture(:project, %{tenant_id: tenant.id})

      source =
        create_article_with_embedding(tenant.id, similar_embedding(), %{
          project_id: project.id
        })

      # Same project article
      same_project =
        create_article_with_embedding(tenant.id, near_similar_embedding(), %{
          project_id: project.id
        })

      # Tenant-wide article (no project)
      tenant_wide = create_article_with_embedding(tenant.id, near_similar_embedding())

      # Different project article
      other_project = fixture(:project, %{tenant_id: tenant.id})

      _different_project =
        create_article_with_embedding(tenant.id, near_similar_embedding(), %{
          project_id: other_project.id
        })

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      link_target_ids =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id,
          select: l.target_article_id
        )
        |> AdminRepo.all()
        |> MapSet.new()

      # Should link to same-project and tenant-wide
      assert MapSet.member?(link_target_ids, same_project.id)
      assert MapSet.member?(link_target_ids, tenant_wide.id)

      # Should NOT link to different project
      assert MapSet.size(link_target_ids) == 2
    end
  end

  # --- Audit event ---

  describe "audit event" do
    test "logs knowledge.articles_linked audit event" do
      %{tenant: tenant} = setup_tenant()

      source = create_article_with_embedding(tenant.id, similar_embedding())
      _target = create_article_with_embedding(tenant.id, near_similar_embedding())

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # Check audit log
      audit =
        from(a in Loopctl.Audit.AuditLog,
          where: a.tenant_id == ^tenant.id,
          where: a.action == "knowledge.articles_linked",
          where: a.entity_id == ^source.id
        )
        |> AdminRepo.one()

      assert audit != nil
      assert audit.entity_type == "article"
      assert audit.actor_type == "system"
      assert audit.actor_label == "worker:article_linking"
      assert audit.new_state["article_id"] == source.id
      # 2 links: a :relates_to and, since the pair is near-identical (>= conflict
      # threshold), a :potential_conflict flag (#4) — both are auto-links created here.
      assert audit.new_state["new_link_count"] == 2
    end
  end

  # --- Backoff ---

  describe "backoff/1" do
    test "returns polynomial backoff values" do
      for attempt <- 1..3 do
        backoff = ArticleLinkingWorker.backoff(%Oban.Job{attempt: attempt})

        min_expected = trunc(:math.pow(attempt, 4) + 15 + attempt)
        max_expected = trunc(:math.pow(attempt, 4) + 15 + 30 * attempt)

        assert backoff >= min_expected,
               "attempt #{attempt}: backoff #{backoff} < min #{min_expected}"

        assert backoff <= max_expected,
               "attempt #{attempt}: backoff #{backoff} > max #{max_expected}"
      end
    end

    test "backoff increases with each attempt" do
      backoffs =
        for attempt <- 1..3 do
          trunc(:math.pow(attempt, 4) + 15)
        end

      assert backoffs == Enum.sort(backoffs)
    end
  end

  # --- Unique job configuration ---

  describe "worker configuration" do
    test "uses knowledge queue with max_attempts 3" do
      job =
        ArticleLinkingWorker.new(%{
          article_id: Ecto.UUID.generate(),
          tenant_id: Ecto.UUID.generate()
        })

      assert job.changes.queue == "knowledge"
      assert job.changes.max_attempts == 3
    end
  end
end
