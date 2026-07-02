defmodule Loopctl.KnowledgeTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.Categories

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  defp setup_tenant_with_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project}
  end

  # --- TC-19.3.1: Create article, verify audit log entry ---

  describe "create_article/3" do
    test "creates article with valid attributes and records audit log" do
      %{tenant: tenant} = setup_tenant()

      attrs = %{
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        tags: ["ecto", "transactions"]
      }

      actor_id = Ecto.UUID.generate()

      assert {:ok, %Article{} = article} =
               Knowledge.create_article(tenant.id, attrs,
                 actor_id: actor_id,
                 actor_label: "user:test"
               )

      assert article.tenant_id == tenant.id
      assert article.title == "Ecto Multi Pattern"
      assert article.body == "Use Ecto.Multi for atomic operations."
      assert article.category == :pattern
      assert article.status == :draft
      assert article.tags == ["ecto", "transactions"]

      # Verify audit log entry exists
      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.created"
        )
        |> AdminRepo.one!()

      assert audit.tenant_id == tenant.id
      assert audit.actor_id == actor_id
      assert audit.actor_label == "user:test"
      assert audit.new_state["title"] == "Ecto Multi Pattern"
      assert audit.new_state["category"] == "pattern"
      assert audit.new_state["status"] == "draft"
    end

    test "returns error changeset for invalid attributes" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, changeset} = Knowledge.create_article(tenant.id, %{})
      assert %{title: _, body: _, category: _} = errors_on(changeset)
    end

    test "sets tenant_id programmatically" do
      %{tenant: tenant} = setup_tenant()

      attrs = %{
        title: "Test Article",
        body: "Body content.",
        category: :convention
      }

      assert {:ok, article} = Knowledge.create_article(tenant.id, attrs)
      assert article.tenant_id == tenant.id
    end

    test "accepts actor_type option" do
      %{tenant: tenant} = setup_tenant()

      attrs = %{
        title: "Test Actor Type",
        body: "Body content.",
        category: :decision
      }

      assert {:ok, article} =
               Knowledge.create_article(tenant.id, attrs, actor_type: "system")

      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id
        )
        |> AdminRepo.one!()

      assert audit.actor_type == "system"
    end
  end

  describe "create_article/3 concurrent-title conflict resolution (#113/#114)" do
    test "idempotently returns the existing article when the body is identical" do
      %{tenant: tenant} = setup_tenant()

      attrs = %{title: "Captured Note", body: "  the same body\n", category: :reference}

      assert {:ok, first} = Knowledge.create_article(tenant.id, attrs)
      # A retry/concurrent duplicate of the same content returns the same row
      # (tagged :deduplicated), even with cosmetic whitespace and tag changes.
      assert {:ok, :deduplicated, second} =
               Knowledge.create_article(
                 tenant.id,
                 %{attrs | body: "the same body"} |> Map.put(:tags, ["extra"])
               )

      assert second.id == first.id
      assert second.body == "  the same body\n", "idempotent return does not overwrite the row"
    end

    test "returns {:error, :duplicate_title, existing} when the body differs" do
      %{tenant: tenant} = setup_tenant()

      assert {:ok, existing} =
               Knowledge.create_article(tenant.id, %{
                 title: "Unique Title",
                 body: "original",
                 category: :pattern
               })

      assert {:error, :duplicate_title, returned} =
               Knowledge.create_article(tenant.id, %{
                 title: "Unique Title",
                 body: "different content",
                 category: :convention
               })

      assert returned.id == existing.id
      # The existing article is untouched.
      {:ok, reloaded} = Knowledge.get_article(tenant.id, existing.id)
      assert reloaded.body == "original"
      assert reloaded.category == :pattern
    end

    test "the active-title unique constraint is attributed to :title, not :tenant_id" do
      changeset =
        Article.create_changeset(%Article{}, %{title: "x", body: "b", category: :pattern})

      assert Enum.any?(changeset.constraints, fn c ->
               c.field == :title and c.constraint == "articles_tenant_title_active_idx"
             end)

      refute Enum.any?(changeset.constraints, fn c ->
               c.field == :tenant_id and c.constraint == "articles_tenant_title_active_idx"
             end)
    end
  end

  describe "create_article/3 idempotency_key (#137)" do
    test "a repeat capture with the same idempotency_key returns the existing row, body ignored" do
      %{tenant: tenant} = setup_tenant()

      assert {:ok, first} =
               Knowledge.create_article(tenant.id, %{
                 title: "Note 1",
                 body: "original body",
                 category: :reference,
                 idempotency_key: "k1"
               })

      # Same key, different title AND body — the key is the identity, so this is a
      # clean no-op (no partial duplicate, existing row unchanged).
      assert {:ok, :deduplicated, second} =
               Knowledge.create_article(tenant.id, %{
                 title: "Note 1 renamed",
                 body: "changed body",
                 category: :reference,
                 idempotency_key: "k1"
               })

      assert second.id == first.id
      assert second.body == "original body"
    end

    test "distinct idempotency_keys create distinct articles" do
      %{tenant: tenant} = setup_tenant()

      assert {:ok, a} =
               Knowledge.create_article(tenant.id, %{
                 title: "A",
                 body: "a",
                 category: :reference,
                 idempotency_key: "ka"
               })

      assert {:ok, b} =
               Knowledge.create_article(tenant.id, %{
                 title: "B",
                 body: "b",
                 category: :reference,
                 idempotency_key: "kb"
               })

      assert a.id != b.id
    end

    test "the same idempotency_key in another tenant does not collide (isolation)" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      attrs = %{title: "Iso", body: "x", category: :reference, idempotency_key: "shared"}

      assert {:ok, a} = Knowledge.create_article(tenant_a.id, attrs)
      assert {:ok, b} = Knowledge.create_article(tenant_b.id, attrs)
      assert a.id != b.id
    end
  end

  describe "bulk_archive/3 (#136)" do
    test "archives draft/published, skips archived/superseded, reports not_found, partial-success" do
      %{tenant: tenant} = setup_tenant()
      d = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      p = fixture(:article, %{tenant_id: tenant.id, status: :published})
      arch = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      missing = Ecto.UUID.generate()

      assert {:ok, result} =
               Knowledge.bulk_archive(tenant.id, [d.id, p.id, arch.id, missing], [])

      assert result.counts == %{requested: 4, archived: 2, skipped: 1, not_found: 1, errored: 0}
      assert AdminRepo.get!(Article, d.id).status == :archived
      assert AdminRepo.get!(Article, p.id).status == :archived
    end

    test "empty / over-cap article_ids are rejected" do
      %{tenant: tenant} = setup_tenant()
      assert {:error, :bad_request, _} = Knowledge.bulk_archive(tenant.id, [], [])
    end

    test "is tenant-scoped (cannot archive another tenant's article)" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()
      b = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      assert {:ok, result} = Knowledge.bulk_archive(tenant_a.id, [b.id], [])
      assert result.counts.not_found == 1
      assert AdminRepo.get!(Article, b.id).status == :published
    end

    test "list_archivable_ids returns active matches and is tenant-scoped" do
      %{tenant: tenant} = setup_tenant()
      %{tenant: other} = setup_tenant()
      src = Ecto.UUID.generate()

      keep =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          source_type: "web_article",
          source_id: src
        })

      _archived =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :archived,
          source_type: "web_article",
          source_id: src
        })

      _other =
        fixture(:article, %{
          tenant_id: other.id,
          status: :published,
          source_type: "web_article",
          source_id: src
        })

      assert {:ok, ids} =
               Knowledge.list_archivable_ids(tenant.id,
                 source_type: "web_article",
                 source_id: src
               )

      assert ids == [keep.id]
    end
  end

  # --- TC-19.3.2: List with tag overlap filtering ---

  describe "list_articles/2 source + idempotency filters (#134)" do
    test "filters by source_type, source_id, and idempotency_key" do
      %{tenant: tenant} = setup_tenant()
      src = Ecto.UUID.generate()

      {:ok, _a} =
        Knowledge.create_article(tenant.id, %{
          title: "From Source",
          body: "b",
          category: :reference,
          source_type: "web_article",
          source_id: src,
          idempotency_key: "ik-1"
        })

      {:ok, _b} =
        Knowledge.create_article(tenant.id, %{title: "Other", body: "b", category: :reference})

      assert %{meta: %{total_count: 1}} =
               Knowledge.list_articles(tenant.id, source_type: "web_article")

      assert %{meta: %{total_count: 1}} = Knowledge.list_articles(tenant.id, source_id: src)

      assert %{meta: %{total_count: 1}} =
               Knowledge.list_articles(tenant.id, idempotency_key: "ik-1")
    end

    test "a well-formed but absent source_id returns zero (the common 'exists? no')" do
      %{tenant: tenant} = setup_tenant()

      {:ok, _} =
        Knowledge.create_article(tenant.id, %{title: "X", body: "b", category: :reference})

      assert %{meta: %{total_count: 0}} =
               Knowledge.list_articles(tenant.id, source_id: Ecto.UUID.generate())
    end

    test "a malformed source_id matches nothing (no raise)" do
      %{tenant: tenant} = setup_tenant()

      {:ok, _} =
        Knowledge.create_article(tenant.id, %{title: "X", body: "b", category: :reference})

      assert %{meta: %{total_count: 0}} =
               Knowledge.list_articles(tenant.id, source_id: "not-a-uuid")
    end

    test "source/idempotency filters are tenant-scoped (no cross-tenant leak)" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      {:ok, _} =
        Knowledge.create_article(tenant_b.id, %{
          title: "B's",
          body: "b",
          category: :reference,
          idempotency_key: "shared-key"
        })

      # Tenant A cannot see tenant B's article by the shared key.
      assert %{meta: %{total_count: 0}} =
               Knowledge.list_articles(tenant_a.id, idempotency_key: "shared-key")
    end
  end

  describe "list_articles/2 tag filtering" do
    test "filters articles by tag overlap (ANY match)" do
      %{tenant: tenant} = setup_tenant()

      {:ok, _a1} =
        Knowledge.create_article(tenant.id, %{
          title: "Elixir Patterns",
          body: "Body",
          category: :pattern,
          tags: ["elixir", "otp"]
        })

      {:ok, _a2} =
        Knowledge.create_article(tenant.id, %{
          title: "Phoenix LiveView",
          body: "Body",
          category: :pattern,
          tags: ["phoenix", "liveview"]
        })

      {:ok, _a3} =
        Knowledge.create_article(tenant.id, %{
          title: "Ecto Patterns",
          body: "Body",
          category: :pattern,
          tags: ["elixir", "ecto"]
        })

      # Filter by "elixir" tag -- should match a1 and a3
      result = Knowledge.list_articles(tenant.id, tags: ["elixir"])
      assert length(result.data) == 2
      titles = Enum.map(result.data, & &1.title)
      assert "Elixir Patterns" in titles
      assert "Ecto Patterns" in titles
    end
  end

  # --- TC-19.3.3: List filtered by category AND project_id ---

  describe "list_articles/2 combined filters" do
    test "filters by category and project_id" do
      %{tenant: tenant, project: project} = setup_tenant_with_project()
      project2 = fixture(:project, %{tenant_id: tenant.id})

      {:ok, _a1} =
        Knowledge.create_article(tenant.id, %{
          title: "Pattern A",
          body: "Body",
          category: :pattern,
          project_id: project.id
        })

      {:ok, _a2} =
        Knowledge.create_article(tenant.id, %{
          title: "Convention A",
          body: "Body",
          category: :convention,
          project_id: project.id
        })

      {:ok, _a3} =
        Knowledge.create_article(tenant.id, %{
          title: "Pattern B",
          body: "Body",
          category: :pattern,
          project_id: project2.id
        })

      result =
        Knowledge.list_articles(tenant.id,
          category: :pattern,
          project_id: project.id
        )

      assert length(result.data) == 1
      assert hd(result.data).title == "Pattern A"
    end

    test "filters by status" do
      %{tenant: tenant} = setup_tenant()

      {:ok, _published} =
        Knowledge.create_article(tenant.id, %{
          title: "Published Article",
          body: "Body",
          category: :pattern,
          status: :published
        })

      {:ok, _draft} =
        Knowledge.create_article(tenant.id, %{
          title: "Draft Article",
          body: "Body",
          category: :pattern
        })

      result = Knowledge.list_articles(tenant.id, status: :published)
      assert length(result.data) == 1
      assert hd(result.data).title == "Published Article"
    end
  end

  # --- TC-19.3.4: Get article preloads outgoing and incoming links ---

  describe "get_article/2" do
    test "preloads outgoing links with target articles and incoming links with source articles" do
      %{tenant: tenant} = setup_tenant()

      {:ok, source} =
        Knowledge.create_article(tenant.id, %{
          title: "Source Article",
          body: "Body",
          category: :pattern
        })

      {:ok, target} =
        Knowledge.create_article(tenant.id, %{
          title: "Target Article",
          body: "Body",
          category: :convention
        })

      {:ok, _link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })

      # Verify source article has outgoing link with target preloaded
      {:ok, fetched_source} = Knowledge.get_article(tenant.id, source.id)
      assert length(fetched_source.outgoing_links) == 1
      outgoing = hd(fetched_source.outgoing_links)
      assert outgoing.target_article.id == target.id
      assert outgoing.target_article.title == "Target Article"

      # Verify target article has incoming link with source preloaded
      {:ok, fetched_target} = Knowledge.get_article(tenant.id, target.id)
      assert length(fetched_target.incoming_links) == 1
      incoming = hd(fetched_target.incoming_links)
      assert incoming.source_article.id == source.id
      assert incoming.source_article.title == "Source Article"
    end

    test "returns {:error, :not_found} for non-existent article" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :not_found} =
               Knowledge.get_article(tenant.id, Ecto.UUID.generate())
    end
  end

  # --- TC-19.3.5: Archive article sets status to :archived + audit log ---

  describe "archive_article/3" do
    test "sets status to :archived and records audit log" do
      %{tenant: tenant} = setup_tenant()
      actor_id = Ecto.UUID.generate()

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "To Archive",
          body: "Body",
          category: :pattern,
          status: :published
        })

      assert {:ok, archived} =
               Knowledge.archive_article(tenant.id, article.id,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      assert archived.status == :archived

      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.archived"
        )
        |> AdminRepo.one!()

      assert audit.actor_id == actor_id
      assert audit.old_state["status"] == "published"
      assert audit.new_state["status"] == "archived"
    end

    test "returns {:error, :not_found} for non-existent article" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :not_found} =
               Knowledge.archive_article(tenant.id, Ecto.UUID.generate())
    end
  end

  # --- TC-19.3.6: Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A cannot access tenant B's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      {:ok, article_a} =
        Knowledge.create_article(tenant_a.id, %{
          title: "Tenant A Article",
          body: "Body",
          category: :pattern
        })

      {:ok, article_b} =
        Knowledge.create_article(tenant_b.id, %{
          title: "Tenant B Article",
          body: "Body",
          category: :pattern
        })

      # Tenant A cannot get tenant B's article
      assert {:error, :not_found} =
               Knowledge.get_article(tenant_a.id, article_b.id)

      # Tenant B cannot get tenant A's article
      assert {:error, :not_found} =
               Knowledge.get_article(tenant_b.id, article_a.id)

      # list_articles returns only own tenant's articles
      result_a = Knowledge.list_articles(tenant_a.id)
      assert length(result_a.data) == 1
      assert hd(result_a.data).id == article_a.id

      result_b = Knowledge.list_articles(tenant_b.id)
      assert length(result_b.data) == 1
      assert hd(result_b.data).id == article_b.id
    end

    test "tenant A cannot update or archive tenant B's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      {:ok, article_b} =
        Knowledge.create_article(tenant_b.id, %{
          title: "Tenant B Article",
          body: "Body",
          category: :pattern
        })

      assert {:error, :not_found} =
               Knowledge.update_article(tenant_a.id, article_b.id, %{title: "Hacked"})

      assert {:error, :not_found} =
               Knowledge.archive_article(tenant_a.id, article_b.id)
    end

    test "tenant A cannot delete tenant B's links" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      link_b = fixture(:article_link, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} =
               Knowledge.delete_link(tenant_a.id, link_b.id)
    end
  end

  # --- TC-19.3.7: Create link validates both articles belong to same tenant ---

  describe "create_link/2" do
    test "creates link between articles in same tenant" do
      %{tenant: tenant} = setup_tenant()

      {:ok, source} =
        Knowledge.create_article(tenant.id, %{
          title: "Source",
          body: "Body",
          category: :pattern
        })

      {:ok, target} =
        Knowledge.create_article(tenant.id, %{
          title: "Target",
          body: "Body",
          category: :convention
        })

      assert {:ok, %ArticleLink{} = link} =
               Knowledge.create_link(tenant.id, %{
                 source_article_id: source.id,
                 target_article_id: target.id,
                 relationship_type: :relates_to
               })

      assert link.tenant_id == tenant.id
      assert link.source_article_id == source.id
      assert link.target_article_id == target.id
      assert link.relationship_type == :relates_to

      # Verify audit log
      audit =
        from(a in AuditLog,
          where: a.entity_type == "article_link" and a.entity_id == ^link.id,
          where: a.action == "article_link.created"
        )
        |> AdminRepo.one!()

      assert audit.tenant_id == tenant.id
    end

    # kb-02: caller-supplied provenance/score flags are SYSTEM-reserved and must be
    # stripped so a link created via create_link can never be laundered into a
    # system-stamped potential_conflict by the nightly promote_conflicts pass.
    test "strips system-reserved metadata keys from caller input" do
      %{tenant: tenant} = setup_tenant()

      {:ok, source} =
        Knowledge.create_article(tenant.id, %{title: "S", body: "B", category: :pattern})

      {:ok, target} =
        Knowledge.create_article(tenant.id, %{title: "T", body: "B", category: :pattern})

      assert {:ok, %ArticleLink{} = link} =
               Knowledge.create_link(tenant.id, %{
                 source_article_id: source.id,
                 target_article_id: target.id,
                 relationship_type: :relates_to,
                 metadata: %{
                   "auto_generated" => true,
                   "similarity_score" => 0.99,
                   "reason" => "kept"
                 }
               })

      refute Map.has_key?(link.metadata, "auto_generated")
      refute Map.has_key?(link.metadata, "similarity_score")
      # Non-reserved keys are preserved.
      assert link.metadata["reason"] == "kept"
    end

    test "rejects link when source article belongs to different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      {:ok, source_b} =
        Knowledge.create_article(tenant_b.id, %{
          title: "Other Tenant Source",
          body: "Body",
          category: :pattern
        })

      {:ok, target_a} =
        Knowledge.create_article(tenant_a.id, %{
          title: "Target",
          body: "Body",
          category: :pattern
        })

      assert {:error, changeset} =
               Knowledge.create_link(tenant_a.id, %{
                 source_article_id: source_b.id,
                 target_article_id: target_a.id,
                 relationship_type: :relates_to
               })

      assert %{source_article_id: ["does not exist in this tenant"]} =
               errors_on(changeset)
    end

    test "rejects link when target article belongs to different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      {:ok, source_a} =
        Knowledge.create_article(tenant_a.id, %{
          title: "Source",
          body: "Body",
          category: :pattern
        })

      {:ok, target_b} =
        Knowledge.create_article(tenant_b.id, %{
          title: "Other Tenant Target",
          body: "Body",
          category: :pattern
        })

      assert {:error, changeset} =
               Knowledge.create_link(tenant_a.id, %{
                 source_article_id: source_a.id,
                 target_article_id: target_b.id,
                 relationship_type: :relates_to
               })

      assert %{target_article_id: ["does not exist in this tenant"]} =
               errors_on(changeset)
    end

    test "supersedes link sets target article status to :superseded" do
      %{tenant: tenant} = setup_tenant()

      {:ok, old_article} =
        Knowledge.create_article(tenant.id, %{
          title: "Old Convention",
          body: "Body",
          category: :convention,
          status: :published
        })

      {:ok, new_article} =
        Knowledge.create_article(tenant.id, %{
          title: "New Convention",
          body: "Body",
          category: :convention,
          status: :published
        })

      assert {:ok, _link} =
               Knowledge.create_link(tenant.id, %{
                 source_article_id: new_article.id,
                 target_article_id: old_article.id,
                 relationship_type: :supersedes
               })

      # Verify the target article is now superseded
      {:ok, refreshed_old} = Knowledge.get_article(tenant.id, old_article.id)
      assert refreshed_old.status == :superseded
    end
  end

  # --- TC-19.3.8: Pagination defaults and limits ---

  describe "list_articles/2 pagination" do
    test "defaults to limit 20 and offset 0" do
      %{tenant: tenant} = setup_tenant()

      result = Knowledge.list_articles(tenant.id)

      assert result.meta.limit == 20
      assert result.meta.offset == 0
      assert result.meta.total_count == 0
      assert result.data == []
    end

    test "honors a limit above 100 up to the max page size (#148 A1)" do
      %{tenant: tenant} = setup_tenant()

      # The old behavior silently clamped to 100, truncating result sets and
      # causing callers advancing offset by the requested limit to skip rows.
      result = Knowledge.list_articles(tenant.id, limit: 500)
      assert result.meta.limit == 500
    end

    test "clamps a limit above the max page size to the max as an internal safety net (#148 A1)" do
      %{tenant: tenant} = setup_tenant()

      result = Knowledge.list_articles(tenant.id, limit: Knowledge.max_page_size() + 1)
      assert result.meta.limit == Knowledge.max_page_size()
    end

    test "respects custom limit and offset" do
      %{tenant: tenant} = setup_tenant()

      # Create 5 articles
      for i <- 1..5 do
        Knowledge.create_article(tenant.id, %{
          title: "Article #{i}",
          body: "Body #{i}",
          category: :pattern
        })
      end

      result = Knowledge.list_articles(tenant.id, limit: 2, offset: 0)
      assert length(result.data) == 2
      assert result.meta.total_count == 5
      assert result.meta.limit == 2
      assert result.meta.offset == 0

      result2 = Knowledge.list_articles(tenant.id, limit: 2, offset: 2)
      assert length(result2.data) == 2
      assert result2.meta.total_count == 5
      assert result2.meta.offset == 2
    end

    test "returns correct total_count with filters applied" do
      %{tenant: tenant} = setup_tenant()

      for i <- 1..3 do
        Knowledge.create_article(tenant.id, %{
          title: "Pattern #{i}",
          body: "Body",
          category: :pattern
        })
      end

      Knowledge.create_article(tenant.id, %{
        title: "Convention 1",
        body: "Body",
        category: :convention
      })

      result = Knowledge.list_articles(tenant.id, category: :pattern)
      assert result.meta.total_count == 3
      assert length(result.data) == 3
    end
  end

  # --- Additional coverage ---

  describe "update_article/4" do
    test "updates article and records audit log with old and new state" do
      %{tenant: tenant} = setup_tenant()
      actor_id = Ecto.UUID.generate()

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Original Title",
          body: "Original body",
          category: :pattern
        })

      assert {:ok, updated} =
               Knowledge.update_article(tenant.id, article.id, %{title: "Updated Title"},
                 actor_id: actor_id,
                 actor_label: "user:editor"
               )

      assert updated.title == "Updated Title"
      assert updated.body == "Original body"

      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.updated"
        )
        |> AdminRepo.one!()

      assert audit.old_state["title"] == "Original Title"
      assert audit.new_state["title"] == "Updated Title"
    end

    test "returns {:error, :not_found} for non-existent article" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :not_found} =
               Knowledge.update_article(tenant.id, Ecto.UUID.generate(), %{
                 title: "No such article"
               })
    end
  end

  describe "delete_link/2" do
    test "deletes link and records audit log" do
      %{tenant: tenant} = setup_tenant()

      {:ok, source} =
        Knowledge.create_article(tenant.id, %{
          title: "Source",
          body: "Body",
          category: :pattern
        })

      {:ok, target} =
        Knowledge.create_article(tenant.id, %{
          title: "Target",
          body: "Body",
          category: :pattern
        })

      {:ok, link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })

      assert {:ok, deleted} = Knowledge.delete_link(tenant.id, link.id)
      assert deleted.id == link.id

      # Verify audit log
      audit =
        from(a in AuditLog,
          where: a.entity_type == "article_link" and a.entity_id == ^link.id,
          where: a.action == "article_link.deleted"
        )
        |> AdminRepo.one!()

      assert audit.old_state["relationship_type"] == "relates_to"
    end

    test "returns {:error, :not_found} for non-existent link" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :not_found} =
               Knowledge.delete_link(tenant.id, Ecto.UUID.generate())
    end
  end

  describe "list_links_for_article/2" do
    test "returns outgoing and incoming links with articles preloaded" do
      %{tenant: tenant} = setup_tenant()

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Center",
          body: "Body",
          category: :pattern
        })

      {:ok, outgoing_target} =
        Knowledge.create_article(tenant.id, %{
          title: "Outgoing Target",
          body: "Body",
          category: :pattern
        })

      {:ok, incoming_source} =
        Knowledge.create_article(tenant.id, %{
          title: "Incoming Source",
          body: "Body",
          category: :pattern
        })

      {:ok, _outgoing_link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: article.id,
          target_article_id: outgoing_target.id,
          relationship_type: :relates_to
        })

      {:ok, _incoming_link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: incoming_source.id,
          target_article_id: article.id,
          relationship_type: :derived_from
        })

      links = Knowledge.list_links_for_article(tenant.id, article.id)
      assert length(links) == 2

      # All links should have source and target articles preloaded
      Enum.each(links, fn link ->
        assert %Article{} = link.source_article
        assert %Article{} = link.target_article
      end)
    end
  end

  describe "stats/2" do
    test "aggregates total, by_category, and by_status across all statuses" do
      tenant = fixture(:tenant)

      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :draft})
      fixture(:article, %{tenant_id: tenant.id, category: :reference, status: :archived})

      stats = Knowledge.stats(tenant.id)

      assert stats.total == 3

      # Dense maps: every category (canonical taxonomy) and all 4 statuses
      # present, 0 when none. Derived from Categories so adding a category can't
      # silently break this expectation.
      expected_by_category =
        Categories.all_strings()
        |> Map.new(&{&1, 0})
        |> Map.merge(%{"pattern" => 2, "reference" => 1})

      assert stats.by_category == expected_by_category

      assert stats.by_status == %{
               "draft" => 1,
               "published" => 1,
               "archived" => 1,
               "superseded" => 0
             }
    end

    test "returns dense zero-filled maps for a tenant with no articles" do
      tenant = fixture(:tenant)

      assert Knowledge.stats(tenant.id) == %{
               total: 0,
               by_category: Map.new(Categories.all_strings(), &{&1, 0}),
               by_status: %{
                 "draft" => 0,
                 "published" => 0,
                 "archived" => 0,
                 "superseded" => 0
               }
             }
    end

    test "project scope counts tenant-wide + project articles, not other projects" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other = fixture(:project, %{tenant_id: tenant.id})

      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        category: :convention,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other.id,
        category: :finding,
        status: :published
      })

      stats = Knowledge.stats(tenant.id, project_id: project.id)

      assert stats.total == 2
      assert stats.by_category["pattern"] == 1
      assert stats.by_category["convention"] == 1
      # other project's :finding article is excluded
      assert stats.by_category["finding"] == 0
    end

    test "tenant isolation: counts never include another tenant's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:article, %{tenant_id: tenant_a.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant_b.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant_b.id, category: :convention, status: :draft})

      stats = Knowledge.stats(tenant_a.id)
      assert stats.total == 1
      assert stats.by_category["pattern"] == 1
      # tenant B's convention article must not leak in
      assert stats.by_category["convention"] == 0
      assert stats.by_status["published"] == 1
    end
  end
end
