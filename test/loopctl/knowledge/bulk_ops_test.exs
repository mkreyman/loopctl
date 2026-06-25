defmodule Loopctl.Knowledge.BulkOpsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.BulkDeleteToken
  alias Loopctl.Knowledge.BulkOps

  defp audit_opts do
    [actor_type: "api_key", actor_id: Ecto.UUID.generate(), actor_label: "user:tester"]
  end

  defp reload_status(id), do: AdminRepo.get!(Article, id).status

  defp bulk_audits(tenant_id, action) do
    from(a in AuditLog,
      where: a.tenant_id == ^tenant_id and a.entity_type == "article_bulk" and a.action == ^action
    )
    |> AdminRepo.all()
  end

  # --- TC-27.12.1: archive by tag is set-based and tenant-scoped ---

  describe "archive/3 by tag (TC-27.12.1, AC-27.12.1/.6/.8)" do
    test "archives all tenant_a tagged articles, leaves tenant_b untouched, one audit event" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a1 = fixture(:article, %{tenant_id: tenant_a.id, status: :published, tags: ["cleanup"]})
      a2 = fixture(:article, %{tenant_id: tenant_a.id, status: :draft, tags: ["cleanup"]})
      b1 = fixture(:article, %{tenant_id: tenant_b.id, status: :published, tags: ["cleanup"]})

      assert {:ok, %{affected: 2}} =
               BulkOps.archive(tenant_a.id, {:tag, "cleanup"}, audit_opts())

      assert reload_status(a1.id) == :archived
      assert reload_status(a2.id) == :archived
      # tenant_b's same-tag article is untouched
      assert reload_status(b1.id) == :published

      # Set-based: exactly ONE audit row (not per-row), with the affected count.
      audits = bulk_audits(tenant_a.id, "article.bulk_archived")
      assert length(audits) == 1
      assert hd(audits).metadata["affected_count"] == 2
      assert hd(audits).metadata["selector"]["type"] == "tag"
    end

    test "idempotent: re-running archive is a no-op (affected: 0, no second audit)" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["dup"]})

      assert {:ok, %{affected: 1}} = BulkOps.archive(tenant.id, {:tag, "dup"}, audit_opts())
      assert {:ok, %{affected: 0}} = BulkOps.archive(tenant.id, {:tag, "dup"}, audit_opts())

      # The no-op run still records its (zero-affected) audit event, but no rows moved.
      audits = bulk_audits(tenant.id, "article.bulk_archived")
      assert Enum.map(audits, & &1.metadata["affected_count"]) |> Enum.sort() == [0, 1]
    end
  end

  describe "archive/3 by ids and source" do
    test "ids selector ANDs tenant_id so foreign ids are never touched (AC-27.12.6)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      mine = fixture(:article, %{tenant_id: tenant_a.id, status: :published})
      theirs = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      assert {:ok, %{affected: 1}} =
               BulkOps.archive(tenant_a.id, {:ids, [mine.id, theirs.id]}, audit_opts())

      assert reload_status(mine.id) == :archived
      # the foreign id is filtered out, never touched
      assert reload_status(theirs.id) == :published
    end

    test "source selector is set-based and tenant-scoped" do
      tenant = fixture(:tenant)
      src = Ecto.UUID.generate()

      a1 =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          source_type: "manual",
          source_id: src
        })

      assert {:ok, %{affected: 1}} = BulkOps.archive(tenant.id, {:source, src}, audit_opts())
      assert reload_status(a1.id) == :archived
    end
  end

  # --- unpublish ---

  describe "unpublish/3 (AC-27.12.1)" do
    test "moves only published rows back to draft; idempotent" do
      tenant = fixture(:tenant)
      pub = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["x"]})
      drafted = fixture(:article, %{tenant_id: tenant.id, status: :draft, tags: ["x"]})

      assert {:ok, %{affected: 1}} = BulkOps.unpublish(tenant.id, {:tag, "x"}, audit_opts())
      assert reload_status(pub.id) == :draft
      assert reload_status(drafted.id) == :draft

      # re-run is a no-op (nothing published)
      assert {:ok, %{affected: 0}} = BulkOps.unpublish(tenant.id, {:tag, "x"}, audit_opts())
    end
  end

  # --- TC-27.12.2: FK-correct delete of a LINKED article ---

  describe "delete/3 FK-correctness (TC-27.12.2, AC-27.12.2)" do
    test "hard-deletes a linked article (inbound + outbound links pre-deleted), one audit" do
      tenant = fixture(:tenant)

      target = fixture(:article, %{tenant_id: tenant.id, status: :published})
      other = fixture(:article, %{tenant_id: tenant.id, status: :published})

      # outbound: target -> other
      out =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: target.id,
          target_article_id: other.id
        })

      # inbound: other -> target
      inb =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: other.id,
          target_article_id: target.id,
          relationship_type: :derived_from
        })

      assert {:ok, %{affected: 1}} = BulkOps.delete(tenant.id, [target.id], audit_opts())

      # article gone, no FK abort
      refute AdminRepo.get(Article, target.id)
      # both links pre-deleted
      refute AdminRepo.get(ArticleLink, out.id)
      refute AdminRepo.get(ArticleLink, inb.id)
      # the partner article survives
      assert AdminRepo.get(Article, other.id)

      audits = bulk_audits(tenant.id, "article.bulk_deleted")
      assert length(audits) == 1
      assert hd(audits).metadata["affected_count"] == 1
    end

    test "cascades article_access_events automatically (no pre-delete needed, AC-27.12.5)" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      event =
        fixture(:article_access_event, %{tenant_id: tenant.id, article_id: article.id})

      assert {:ok, %{affected: 1}} = BulkOps.delete(tenant.id, [article.id], audit_opts())

      refute AdminRepo.get(Article, article.id)
      # access event cascaded
      refute AdminRepo.get(Loopctl.Knowledge.ArticleAccessEvent, event.id)
    end

    test "delete is tenant-scoped: a foreign id in the set is never deleted (AC-27.12.6)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      mine = fixture(:article, %{tenant_id: tenant_a.id, status: :published})
      theirs = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      assert {:ok, %{affected: 1}} =
               BulkOps.delete(tenant_a.id, [mine.id, theirs.id], audit_opts())

      refute AdminRepo.get(Article, mine.id)
      assert AdminRepo.get(Article, theirs.id)
    end
  end

  # --- TC-27.12.4: atomic rollback on a forced mid-tx failure ---

  describe "atomicity (TC-27.12.4, AC-27.12.4)" do
    test "FK-abort from a cross-tenant link rolls the whole delete back (no partial state)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      victim = fixture(:article, %{tenant_id: tenant_a.id, status: :published})
      partner = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      # A same-tenant link that WILL be pre-deleted (so the happy path would work).
      ok_link =
        fixture(:article_link, %{
          tenant_id: tenant_a.id,
          source_article_id: victim.id,
          target_article_id: partner.id
        })

      # Seam: a link owned by tenant_b but pointing at tenant_a's victim. Our
      # tenant-scoped link cleanup (l.tenant_id == ^tenant_a) does NOT delete it,
      # so the :restrict FK on target_article_id aborts the article delete →
      # the whole transaction (incl. ok_link deletion + audit) rolls back.
      stray =
        %ArticleLink{tenant_id: tenant_b.id}
        |> ArticleLink.changeset(%{
          source_article_id: partner.id,
          target_article_id: victim.id,
          relationship_type: :relates_to
        })
        |> Ecto.Changeset.put_change(:tenant_id, tenant_b.id)
        |> AdminRepo.insert!()

      assert {:error, _reason} = BulkOps.delete(tenant_a.id, [victim.id], audit_opts())

      # Full rollback: article still present, the in-tenant link NOT removed,
      # the stray link present, and NO audit event written.
      assert AdminRepo.get(Article, victim.id)
      assert AdminRepo.get(ArticleLink, ok_link.id)
      assert AdminRepo.get(ArticleLink, stray.id)
      assert bulk_audits(tenant_a.id, "article.bulk_deleted") == []
    end
  end

  # --- TC-27.12.5: dry-run + frozen-set token ---

  describe "preview/4 + delete_with_token/3 (TC-27.12.5, AC-27.12.9)" do
    test "dry-run mutates nothing and the tokened delete operates on the FROZEN set" do
      tenant = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["frz"]})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["frz"]})

      assert {:ok, %{would_affect: 2, token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "frz"}, audit_opts())

      assert is_binary(token_id)
      # dry-run mutated nothing
      assert AdminRepo.get(Article, a1.id)
      assert AdminRepo.get(Article, a2.id)

      # A new matching article appears AFTER the preview (TOCTOU).
      a3 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["frz"]})

      # The tokened delete affects the FROZEN 2, not 3.
      assert {:ok, %{affected: 2}} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      refute AdminRepo.get(Article, a1.id)
      refute AdminRepo.get(Article, a2.id)
      # the post-preview article is NOT swept up
      assert AdminRepo.get(Article, a3.id)
    end

    test "token is single-use: a second consumption is refused" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["once"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "once"}, audit_opts())

      assert {:ok, %{affected: 1}} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())
    end

    test "token is refused cross-tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant_a.id, status: :published, tags: ["xt"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant_a.id, :delete, {:tag, "xt"}, audit_opts())

      # tenant_b cannot consume tenant_a's token
      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant_b.id, token_id, audit_opts())

      # and tenant_a's article is untouched
      assert AdminRepo.get(Article, art.id)
    end

    test "expired token is refused" do
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["exp"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "exp"}, audit_opts())

      # force-expire the token
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      from(t in BulkDeleteToken, where: t.id == ^token_id)
      |> AdminRepo.update_all(set: [expires_at: past])

      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      assert AdminRepo.get(Article, art.id)
    end

    test "preview for archive/unpublish returns would_affect and mints NO token (reversible)" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["rev"]})

      assert {:ok, result} = BulkOps.preview(tenant.id, :archive, {:tag, "rev"}, audit_opts())
      assert result.would_affect == 1
      refute Map.has_key?(result, :token)

      # no token rows were minted
      assert AdminRepo.aggregate(BulkDeleteToken, :count, :id) == 0
    end

    test "oversized selector returns no token (oversized: true) for the re-confirm path" do
      # config/test.exs sets :bulk_delete_frozen_max to a low bound (3) so the
      # oversized path is exercisable without seeding thousands of rows — no
      # Application.put_env in the test (config-based DI).
      tenant = fixture(:tenant)
      max = Application.fetch_env!(:loopctl, :bulk_delete_frozen_max)

      for _ <- 1..(max + 1) do
        fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["big"]})
      end

      assert {:ok, %{would_affect: would, token: nil, oversized: true, frozen_ids: ids}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "big"}, audit_opts())

      assert would == max + 1
      assert length(ids) == max + 1
      assert AdminRepo.aggregate(BulkDeleteToken, :count, :id) == 0
    end
  end

  describe "confirm_hash/2" do
    test "is order-independent and tenant-specific" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      assert BulkOps.confirm_hash(tenant_a.id, [id1, id2]) ==
               BulkOps.confirm_hash(tenant_a.id, [id2, id1])

      refute BulkOps.confirm_hash(tenant_a.id, [id1, id2]) ==
               BulkOps.confirm_hash(tenant_b.id, [id1, id2])
    end
  end

  # --- AC-27.12.2 schema-introspection guard ---

  describe "FK inventory guard (AC-27.12.2)" do
    test "only article_links.{source,target}_article_id reference articles with ON DELETE RESTRICT" do
      # If a NEW :restrict FK to articles is added without updating the delete
      # order (links-first), this catches it. article_access_events is :delete_all
      # (cascade), so it is NOT in this set.
      # pg_constraint.confdeltype = 'r' is precisely ON DELETE RESTRICT
      # (information_schema collapses RESTRICT and NO ACTION to "NO ACTION", so we
      # query the catalog directly). 'c' = CASCADE (article_access_events) is
      # intentionally excluded.
      %{rows: rows} =
        AdminRepo.query!(
          """
          SELECT con.conrelid::regclass::text AS table_name,
                 att.attname AS column_name
          FROM pg_constraint con
          JOIN pg_class ref ON ref.oid = con.confrelid
          JOIN unnest(con.conkey) AS k(attnum) ON true
          JOIN pg_attribute att
            ON att.attrelid = con.conrelid AND att.attnum = k.attnum
          WHERE con.contype = 'f'
            AND ref.relname = 'articles'
            AND con.confdeltype = 'r'
          """,
          []
        )

      restrict_fks = rows |> Enum.map(fn [t, c] -> {t, c} end) |> Enum.sort()

      assert restrict_fks == [
               {"article_links", "source_article_id"},
               {"article_links", "target_article_id"}
             ]
    end
  end
end
