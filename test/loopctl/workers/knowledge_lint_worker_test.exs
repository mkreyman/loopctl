defmodule Loopctl.Workers.KnowledgeLintWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Workers.KnowledgeLintWorker

  # A published article with a known embedding vector, written directly via
  # AdminRepo to bypass the inline Oban cascade (embedding -> linking) that
  # `fixture(:article)` would otherwise trigger on publish.
  defp published_article_with_embedding(tenant_id, embedding, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Test article body.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published, embedding: embedding})
    |> AdminRepo.update!()
  end

  # Two near-identical directional vectors -> cosine similarity ~1.0, above the
  # 0.6 linking threshold. (Cosine measures direction, not magnitude.)
  defp similar_embedding, do: List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)

  defp near_similar_embedding do
    List.duplicate(1.0, 768)
    |> List.update_at(0, fn _ -> 0.99 end)
    |> List.update_at(1, fn _ -> 1.01 end)
    |> Kernel.++(List.duplicate(0.01, 768))
  end

  # A published orphan with NO embedding — the case a plain re-link no-ops on.
  defp published_without_embedding(tenant_id) do
    fixture(:article, %{
      tenant_id: tenant_id,
      title: "Article #{System.unique_integer([:positive])}",
      body: "Test article body.",
      category: :pattern,
      tags: []
    })
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp lint_audit_entries(tenant_id) do
    from(a in AuditLog,
      where: a.tenant_id == ^tenant_id,
      where: a.action == "knowledge.lint_completed"
    )
    |> AdminRepo.all()
  end

  describe "perform/1 per-tenant" do
    test "logs a knowledge.lint_completed audit event carrying the lint summary" do
      tenant = fixture(:tenant)
      _article = published_article_with_embedding(tenant.id, similar_embedding())

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.actor_type == "system"
      assert entry.actor_label == "worker:knowledge_lint"
      # new_state is jsonb -> string keys on read
      assert entry.new_state["summary"]["total_articles"] == 1
      assert is_integer(entry.new_state["summary"]["total_issues"])
      assert is_integer(entry.new_state["orphans_relinked"])
      assert is_integer(entry.new_state["orphans_embedding_enqueued"])
    end

    test "re-links orphan articles against the current corpus" do
      tenant = fixture(:tenant)
      # Two similar, published, unlinked articles -> both orphans.
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # Orphan re-link (inline Oban) ran ArticleLinkingWorker -> a relates_to
      # link now connects the previously-orphaned pair.
      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where:
            (l.source_article_id == ^a.id and l.target_article_id == ^b.id) or
              (l.source_article_id == ^b.id and l.target_article_id == ^a.id)
        )
        |> AdminRepo.all()

      assert length(links) == 1

      assert [entry] = lint_audit_entries(tenant.id)
      # Both were embedded orphans, so both were re-linked (not embedding-enqueued).
      assert entry.new_state["summary"]["total_per_category"]["orphan_articles"] == 2
      assert entry.new_state["orphans_relinked"] == 2
      assert entry.new_state["orphans_embedding_enqueued"] == 0
    end

    test "embeds orphans that have no embedding (a plain re-link would no-op them)" do
      tenant = fixture(:tenant)
      orphan = published_without_embedding(tenant.id)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # The embedding worker ran inline (default Mox stub yields a 1536-dim vector)
      # and stored an embedding, so the orphan is no longer un-embeddable.
      reloaded = Loopctl.Knowledge.get_article_with_embedding(tenant.id, orphan.id)
      assert {:ok, %{embedding: embedding}} = reloaded
      refute is_nil(embedding)

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["orphans_relinked"] == 0
      assert entry.new_state["orphans_embedding_enqueued"] == 1
    end

    test "handles a tenant with no published articles" do
      tenant = fixture(:tenant)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["summary"]["total_articles"] == 0
      assert entry.new_state["orphans_relinked"] == 0
      assert entry.new_state["orphans_embedding_enqueued"] == 0
    end
  end

  describe "perform/1 all_tenants mode" do
    test "fans out and lints every active tenant, skipping inactive ones" do
      active_a = fixture(:tenant)
      active_b = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})

      for t <- [active_a, active_b, suspended] do
        published_article_with_embedding(t.id, similar_embedding())
      end

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

      assert [_] = lint_audit_entries(active_a.id)
      assert [_] = lint_audit_entries(active_b.id)
      assert [] == lint_audit_entries(suspended.id)
    end
  end

  describe "tenant isolation" do
    test "lint summary counts only the caller tenant's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      published_article_with_embedding(tenant_a.id, similar_embedding())
      published_article_with_embedding(tenant_a.id, near_similar_embedding())

      published_article_with_embedding(tenant_b.id, similar_embedding())
      published_article_with_embedding(tenant_b.id, near_similar_embedding())
      published_article_with_embedding(tenant_b.id, similar_embedding())

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant_a.id}})

      assert [entry] = lint_audit_entries(tenant_a.id)
      assert entry.new_state["summary"]["total_articles"] == 2
      # Tenant B was never linted.
      assert [] == lint_audit_entries(tenant_b.id)
    end
  end
end
