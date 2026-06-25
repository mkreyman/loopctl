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

    test "source selector with source_type filters by BOTH (mismatched source_type → no match)" do
      # A source_id whose source_type DIFFERS must NOT match: the combined filter
      # ANDs source_type with source_id (the shipped contract). The bare-id form
      # would over-match here; the map form must not.
      tenant = fixture(:tenant)
      src = Ecto.UUID.generate()

      web =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          source_type: "web_article",
          source_id: src
        })

      # Same source_id, DIFFERENT source_type — must be left untouched.
      assert {:ok, %{affected: 0}} =
               BulkOps.archive(
                 tenant.id,
                 {:source, %{source_id: src, source_type: "manual"}},
                 audit_opts()
               )

      assert reload_status(web.id) == :published

      # The MATCHING source_type archives it.
      assert {:ok, %{affected: 1}} =
               BulkOps.archive(
                 tenant.id,
                 {:source, %{source_id: src, source_type: "web_article"}},
                 audit_opts()
               )

      assert reload_status(web.id) == :archived
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

    test "token is single-use: the SECOND consumption is REFUSED (not silently affected:0)" do
      tenant = fixture(:tenant)
      survivor = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["twice"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "twice"}, audit_opts())

      # The frozen set had ONE article; the first run deletes it.
      assert {:ok, %{affected: 1}} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      refute AdminRepo.get(Article, survivor.id)

      # The SECOND run is REFUSED with :invalid_token — NOT a silent {:ok, affected: 0}.
      # The atomic consume gate (is_nil(used_at) in the guarded update_all) is what
      # makes a double-spend impossible even under concurrency.
      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())
    end

    test "double-spend race semantics: a concurrent second consume of a used token is refused" do
      # The race is gated by the single guarded `update_all` that stamps used_at
      # ONLY when is_nil(used_at). Two consumers cannot both stamp it: the second
      # update matches 0 rows → :assert_consumed fails → :invalid_token. We exercise
      # the same gate deterministically by stamping used_at first (as the "winner"
      # transaction would have committed), then asserting the next consume is refused.
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["race"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "race"}, audit_opts())

      # Simulate the winning consumer having already stamped used_at.
      from(t in BulkDeleteToken, where: t.id == ^token_id)
      |> AdminRepo.update_all(set: [used_at: DateTime.utc_now()])

      # The losing consumer's guarded update matches 0 rows → refused, article intact.
      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      assert AdminRepo.get(Article, art.id)
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

    test "token expired exactly at the boundary (expires_at == now) is refused" do
      # The consume guard is `expires_at > now` (strict), so a token whose
      # expires_at is in the past — including the exact boundary — is refused.
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["bnd"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "bnd"}, audit_opts())

      # Force expiry to a fixed past instant so the strict `>` comparison refuses it.
      boundary = DateTime.add(DateTime.utc_now(), -1, :microsecond)

      from(t in BulkDeleteToken, where: t.id == ^token_id)
      |> AdminRepo.update_all(set: [expires_at: boundary])

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

  # --- AC-27.12.5: moderate worst-case integration (NOT :scale) ---

  describe "delete/3 worst-case shape (AC-27.12.5, moderate)" do
    test "hard-deletes ~100 tagged articles with links + access events, one audit, all cascaded" do
      # Discharges AC-27.12.5's document+test branch below the :scale tier: a
      # realistic selector (a whole tag) where each article carries links and
      # several access events. Asserts the single-transaction/one-audit op
      # completes, removes the links (FK :restrict pre-delete), and cascades the
      # access events (FK :delete_all) — the dominant row count for a hot article.
      tenant = fixture(:tenant)
      n = 100

      articles =
        for _ <- 1..n do
          fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["mass"]})
        end

      ids = Enum.map(articles, & &1.id)

      # Chain links a[i] -> a[i+1] so every article has both an inbound and an
      # outbound link (both FK directions exercised), all tenant-scoped.
      link_ids =
        articles
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [src, tgt] ->
          fixture(:article_link, %{
            tenant_id: tenant.id,
            source_article_id: src.id,
            target_article_id: tgt.id
          }).id
        end)

      # Several access events per article (the cascade-by-delete_all cost).
      event_ids =
        Enum.flat_map(articles, fn art ->
          for _ <- 1..3 do
            fixture(:article_access_event, %{tenant_id: tenant.id, article_id: art.id}).id
          end
        end)

      assert {:ok, %{affected: ^n}} = BulkOps.delete(tenant.id, ids, audit_opts())

      # All articles gone, no FK abort.
      assert Enum.all?(ids, fn id -> is_nil(AdminRepo.get(Article, id)) end)
      # Links removed (both directions).
      assert Enum.all?(link_ids, fn id -> is_nil(AdminRepo.get(ArticleLink, id)) end)
      # Access events cascaded.
      assert Enum.all?(event_ids, fn id ->
               is_nil(AdminRepo.get(Loopctl.Knowledge.ArticleAccessEvent, id))
             end)

      # Exactly ONE audit event (AC-27.12.8), with the affected count.
      audits = bulk_audits(tenant.id, "article.bulk_deleted")
      assert length(audits) == 1
      assert hd(audits).metadata["affected_count"] == n
    end
  end

  # --- AC-27.12.3: archived middle node is INERT in published-only traversal ---

  describe "archive makes a middle node inert in graph traversal (AC-27.12.3)" do
    test "a bridge path through an archived middle disappears (published-only middles)" do
      # graph_traversal / distant_pairs traverse PUBLISHED middles only. Archiving
      # a middle leaves its links intact (distinct from delete) but makes it inert:
      # a bridge A -- M -- B no longer connects A to B once M is archived.
      alias Loopctl.Knowledge

      tenant = fixture(:tenant)

      a = fixture(:article, %{tenant_id: tenant.id, status: :published})
      middle = fixture(:article, %{tenant_id: tenant.id, status: :published})
      b = fixture(:article, %{tenant_id: tenant.id, status: :published})

      # A -- middle -- B (the only path from A to B is through `middle`).
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: a.id,
        target_article_id: middle.id
      })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: middle.id,
        target_article_id: b.id
      })

      # Before archiving: depth-2 traversal from A reaches B through the middle.
      assert {:ok, before} = Knowledge.graph_traversal(tenant.id, a.id, depth: 2)
      before_ids = MapSet.new(before.nodes, & &1.id)
      assert MapSet.member?(before_ids, middle.id)
      assert MapSet.member?(before_ids, b.id)

      # Archive the middle (links left intact, but it becomes inert in traversal).
      assert {:ok, %{affected: 1}} =
               BulkOps.archive(tenant.id, {:ids, [middle.id]}, audit_opts())

      # After archiving: the bridge through the now-archived middle disappears —
      # B is no longer reachable from A (the published-only middle filter excludes it).
      assert {:ok, after_trav} = Knowledge.graph_traversal(tenant.id, a.id, depth: 2)
      after_ids = MapSet.new(after_trav.nodes, & &1.id)
      refute MapSet.member?(after_ids, middle.id)
      refute MapSet.member?(after_ids, b.id)
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
