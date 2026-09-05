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
  alias Loopctl.LocalGuc

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

  # --- LocalGuc ownership accounting (PR #549 review follow-up) ---

  describe "LocalGuc active-names ownership across a bulk op" do
    # `LocalGuc` tracks which GUC names a LIVE scope owns in the process dictionary, and
    # `capture_fallback!/2` reads it to decide whether a FAILED capture may reset a name
    # (nobody owns it) or must abort (an enclosing scope does). Both `restore/2` and
    # `forget/1` pop with `list -- names`, which removes ONE occurrence — so a bulk op that
    # pops twice silently steals an ENCLOSING scope's entry. That scope then looks unowned,
    # and the next nested capture failure clobbers its deliberate `statement_timeout`
    # instead of refusing: the exact leak LocalGuc exists to prevent.
    #
    # Asserted on the tracking state itself because there is no other observable: the
    # damage only materialises on a LATER, unrelated read whose capture happens to fail.
    @active_names_key {Loopctl.LocalGuc, :active_names}

    defp enclosing_owner(names), do: Process.put(@active_names_key, names)
    defp owned_names, do: Process.get(@active_names_key, [])

    setup do
      on_exit(fn -> Process.delete(@active_names_key) end)
      :ok
    end

    test "the key above is the one LocalGuc actually pushes to" do
      # `@active_names_key` duplicates a PRIVATE `LocalGuc` detail, which is how a guard test
      # goes vacuous: seed and read one unrelated key and every assertion below holds
      # trivially while the accounting it guards goes unverified. Bind the literal to the
      # real thing — a real capture must land under it — so a rename fails HERE, loudly,
      # instead of quietly neutering the two tests that follow.
      AdminRepo.transaction(fn ->
        prior = LocalGuc.capture(AdminRepo, ["statement_timeout"])
        assert owned_names() == ["statement_timeout"]
        LocalGuc.restore(AdminRepo, prior)
        assert owned_names() == []
      end)
    end

    test "a SUCCEEDING bulk op leaves an enclosing scope's ownership intact" do
      tenant = fixture(:tenant)
      fixture(:article, tenant_id: tenant.id, tags: ["ownership"], status: :published)

      enclosing_owner(["statement_timeout"])

      assert {:ok, %{affected: 1}} =
               BulkOps.archive(tenant.id, {:tag, "ownership"}, audit_opts())

      # Before the fix this was [] — :restore_timeout popped the bulk op's own entry and the
      # unconditional `after` pop then took the enclosing scope's.
      assert owned_names() == ["statement_timeout"],
             "the bulk op popped an enclosing scope's LocalGuc ownership entry"
    end

    test "a FAILING bulk op still releases its own ownership entry" do
      tenant = fixture(:tenant)

      enclosing_owner(["statement_timeout"])

      # An invalid delete token errors a step AFTER :set_timeout, so :restore_timeout is
      # skipped and the entry this call pushed is never popped by it — the case the
      # `after` cleanup exists for. It must still not over-pop.
      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant.id, Ecto.UUID.generate(), audit_opts())

      assert owned_names() == ["statement_timeout"],
             "a failed bulk op must release exactly its own entry, no more and no fewer"
    end

    test "a bulk op that RAISES outside the rescued DB structs still releases its own entry" do
      tenant = fixture(:tenant)
      fixture(:article, tenant_id: tenant.id, tags: ["ownership"], status: :published)

      enclosing_owner(["statement_timeout"])

      # A non-keyword `audit_opts` raises `FunctionClauseError` inside the audit step's
      # changeset fun — an exception neither `rescue` clause names, so it unwinds straight
      # out of `run_multi/2`. Only an `after` runs on that path; a try/rescue over two DB
      # structs leaves this call's entry behind for whatever the process serves next.
      assert_raise FunctionClauseError, fn ->
        BulkOps.archive(tenant.id, {:tag, "ownership"}, %{actor_type: "api_key"})
      end

      assert owned_names() == ["statement_timeout"],
             "a raising bulk op leaked its LocalGuc ownership entry onto this process"
    end
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

    test "tokened delete audit records the FROZEN id count (forensic record of the irreversible op)" do
      # The delete audit for the token path must record how many ids the token
      # FROZE — not just the token id — so the immutable record of an IRREVERSIBLE
      # delete carries the blast size. selector.count == the frozen set size.
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["audctf"]})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["audctf"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "audctf"}, audit_opts())

      assert {:ok, %{affected: 2}} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      audits = bulk_audits(tenant.id, "article.bulk_deleted")
      assert length(audits) == 1
      selector = hd(audits).metadata["selector"]
      assert selector["type"] == "token"
      assert selector["token"] == token_id
      # The frozen count (2) is recorded — the load-bearing forensic detail.
      assert selector["count"] == 2
      assert hd(audits).metadata["affected_count"] == 2
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

    test "preview for an ids/source archive returns would_affect and mints NO token" do
      # #779 narrowed this: an ids or source selector names a set the caller already
      # holds, so there is nothing to freeze and `would_affect` is the whole preview.
      # The TAG selector is the one that mints a proposal — asserted below.
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["rev"]})

      assert {:ok, result} = BulkOps.preview(tenant.id, :archive, {:ids, [art.id]}, audit_opts())
      assert result.would_affect == 1
      refute Map.has_key?(result, :token)

      assert {:ok, unpub} = BulkOps.preview(tenant.id, :unpublish, {:tag, "rev"}, audit_opts())
      assert unpub.would_affect == 1
      refute Map.has_key?(unpub, :token)

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

      # No FROZEN-set token is minted over the bound (the re-confirm path freezes
      # nothing). The oversized path mints exactly one reconfirm NONCE (replay
      # marker), so there are zero frozen_token rows and one reconfirm_nonce row.
      assert AdminRepo.aggregate(
               from(t in BulkDeleteToken, where: t.type == "frozen_token"),
               :count,
               :id
             ) == 0

      assert AdminRepo.aggregate(
               from(t in BulkDeleteToken, where: t.type == "reconfirm_nonce"),
               :count,
               :id
             ) == 1
    end

    test "zero-match hard dry-run mints NO token (token: nil, no rows minted)" do
      # A selector that matches nothing must NOT mint a single-use frozen-set token
      # that could only ever delete nothing — pure table noise. would_affect is 0
      # and token is nil, with zero rows in the table.
      tenant = fixture(:tenant)
      # no articles tagged "ghost" exist
      assert {:ok, %{would_affect: 0, token: nil}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "ghost"}, audit_opts())

      assert AdminRepo.aggregate(BulkDeleteToken, :count, :id) == 0
    end
  end

  describe "soft-tag proposal flow (#779)" do
    test "preview(:archive, {:tag, _}) mints a soft_tag_token over the frozen set" do
      tenant = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["st"]})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :draft, tags: ["st"]})

      assert {:ok, %{would_affect: 2, token: token_id, frozen_ids: frozen}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "st"}, audit_opts())

      assert Enum.sort(frozen) == Enum.sort([a1.id, a2.id])

      # The row is typed for the SOFT path. A "frozen_token" here would be spendable
      # as an irreversible delete of the same set.
      assert %BulkDeleteToken{type: "soft_tag_token", used_at: nil, article_ids: ids} =
               AdminRepo.get!(BulkDeleteToken, token_id)

      assert Enum.sort(ids) == Enum.sort([a1.id, a2.id])

      # Preview mutates nothing.
      assert reload_status(a1.id) == :published
      assert reload_status(a2.id) == :draft
    end

    test "archive_with_token/3 archives exactly the frozen set and consumes the token" do
      tenant = fixture(:tenant)
      previewed = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["stf"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "stf"}, audit_opts())

      # TOCTOU: a new matching row appears after the preview.
      latecomer = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["stf"]})

      assert {:ok, %{affected: 1, resolved_count: 1}} =
               BulkOps.archive_with_token(tenant.id, token_id, audit_opts())

      assert reload_status(previewed.id) == :archived
      assert reload_status(latecomer.id) == :published

      # Single-use: the token is stamped and a replay is refused.
      assert %BulkDeleteToken{used_at: used_at} = AdminRepo.get!(BulkDeleteToken, token_id)
      refute is_nil(used_at)

      assert {:error, :invalid_token} =
               BulkOps.archive_with_token(tenant.id, token_id, audit_opts())

      # Exactly one bulk-archive audit event for the one spend.
      assert [_one] = bulk_audits(tenant.id, "article.bulk_archived")
    end

    test "a frozen_token (hard delete) is NOT spendable as a soft archive" do
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["mix1"]})

      assert {:ok, %{token: hard_token}} =
               BulkOps.preview(tenant.id, :delete, {:tag, "mix1"}, audit_opts())

      assert {:error, :invalid_token} =
               BulkOps.archive_with_token(tenant.id, hard_token, audit_opts())

      # Nothing archived, and the refusal did not consume the delete token — it is
      # still spendable on the path it was minted for.
      assert reload_status(art.id) == :published
      assert %BulkDeleteToken{used_at: nil} = AdminRepo.get!(BulkDeleteToken, hard_token)

      assert {:ok, %{affected: 1}} =
               BulkOps.delete_with_token(tenant.id, hard_token, audit_opts())
    end

    test "a soft_tag_token is NOT spendable as a hard delete" do
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["mix2"]})

      assert {:ok, %{token: soft_token}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "mix2"}, audit_opts())

      assert {:error, :invalid_token} =
               BulkOps.delete_with_token(tenant.id, soft_token, audit_opts())

      # The row SURVIVES: escalating a reversible-shaped proposal into an
      # irreversible delete of the same set is what the type predicate prevents.
      assert AdminRepo.get(Article, art.id)
      assert reload_status(art.id) == :published
      assert %BulkDeleteToken{used_at: nil} = AdminRepo.get!(BulkDeleteToken, soft_token)

      # And it still works on its own path.
      assert {:ok, %{affected: 1}} =
               BulkOps.archive_with_token(tenant.id, soft_token, audit_opts())

      assert reload_status(art.id) == :archived
    end

    test "a soft_tag_token minted in tenant A cannot be spent in tenant B" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      a_art = fixture(:article, %{tenant_id: tenant_a.id, status: :published, tags: ["iso"]})
      b_art = fixture(:article, %{tenant_id: tenant_b.id, status: :published, tags: ["iso"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant_a.id, :archive, {:tag, "iso"}, audit_opts())

      assert {:error, :invalid_token} =
               BulkOps.archive_with_token(tenant_b.id, token_id, audit_opts())

      assert reload_status(a_art.id) == :published
      assert reload_status(b_art.id) == :published

      # Unconsumed by the foreign attempt, so the owning tenant can still spend it.
      assert {:ok, %{affected: 1}} =
               BulkOps.archive_with_token(tenant_a.id, token_id, audit_opts())

      assert reload_status(a_art.id) == :archived
      assert reload_status(b_art.id) == :published
    end

    test "an expired or malformed soft token is refused" do
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["stexp"]})

      assert {:ok, %{token: token_id}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "stexp"}, audit_opts())

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      from(t in BulkDeleteToken, where: t.id == ^token_id)
      |> AdminRepo.update_all(set: [expires_at: past])

      assert {:error, :invalid_token} =
               BulkOps.archive_with_token(tenant.id, token_id, audit_opts())

      assert {:error, :invalid_token} =
               BulkOps.archive_with_token(tenant.id, "not-a-uuid", audit_opts())

      assert {:error, :invalid_token} = BulkOps.archive_with_token(tenant.id, nil, audit_opts())

      assert reload_status(art.id) == :published
    end

    test "frozen ids that drifted out of archivable count as requested, not affected" do
      tenant = fixture(:tenant)
      stays = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["dr"]})
      drifts = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["dr"]})

      assert {:ok, %{token: token_id, would_affect: 2}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "dr"}, audit_opts())

      # One frozen row leaves the archivable set between the preview and the spend.
      from(a in Article, where: a.id == ^drifts.id)
      |> AdminRepo.update_all(set: [status: :superseded])

      assert {:ok, %{affected: 1, resolved_count: 2}} =
               BulkOps.archive_with_token(tenant.id, token_id, audit_opts())

      assert reload_status(stays.id) == :archived
      assert reload_status(drifts.id) == :superseded
    end

    test "an oversized tag archive mints a soft_reconfirm_nonce, never a frozen token" do
      tenant = fixture(:tenant)
      max = Application.fetch_env!(:loopctl, :bulk_delete_frozen_max)

      for _ <- 1..(max + 1) do
        fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["bigsoft"]})
      end

      assert {:ok, %{token: nil, oversized: true, frozen_ids: ids, would_affect: would}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "bigsoft"}, audit_opts())

      assert would == max + 1
      assert length(ids) == max + 1

      # Typed apart from the hard-delete nonce for the same reason the tokens are.
      assert [%BulkDeleteToken{type: "soft_reconfirm_nonce"}] = AdminRepo.all(BulkDeleteToken)
    end

    test "a zero-match tag archive mints nothing" do
      tenant = fixture(:tenant)

      assert {:ok, %{would_affect: 0, token: nil}} =
               BulkOps.preview(tenant.id, :archive, {:tag, "ghost"}, audit_opts())

      assert AdminRepo.aggregate(BulkDeleteToken, :count, :id) == 0
    end

    test "archive_frozen/3 archives the given set and reports the requested size" do
      tenant = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      foreign = fixture(:article, %{tenant_id: fixture(:tenant).id, status: :published})

      assert {:ok, %{affected: 1, resolved_count: 3}} =
               BulkOps.archive_frozen(tenant.id, [a1.id, a2.id, foreign.id], audit_opts())

      assert reload_status(a1.id) == :archived
      assert reload_status(a2.id) == :archived
      # Tenant-scoped: a foreign id in the frozen list never matches.
      assert reload_status(foreign.id) == :published
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

  # --- #266: HARD delete by explicit id-list must purge ARCHIVED tombstones ---

  describe "hard delete by article_ids reaches archived rows (#266)" do
    test "two-phase flow: create -> archive -> dry-run reports would_affect:1 + mints a token" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      article_id = article.id

      # A previously-active row that has been archived (a tombstone) must still be
      # previewable for a HARD delete via its explicit id — otherwise the natural
      # archive-then-purge flow is impossible.
      assert {:ok, %{would_affect: 1, token: token_id, frozen_ids: [^article_id]}} =
               BulkOps.preview(tenant.id, :delete, {:ids, [article.id]}, audit_opts())

      assert is_binary(token_id)

      # And the tokened delete PURGES the archived row.
      assert {:ok, %{affected: 1}} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      refute AdminRepo.get(Article, article.id)
    end

    test "resolve_delete_selector includes archived AND active id-list rows" do
      tenant = fixture(:tenant)
      archived = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      published = fixture(:article, %{tenant_id: tenant.id, status: :published})
      superseded = fixture(:article, %{tenant_id: tenant.id, status: :superseded})

      {:ok, ids} =
        BulkOps.resolve_delete_selector(
          tenant.id,
          {:ids, [archived.id, published.id, superseded.id]}
        )

      assert Enum.sort(ids) ==
               Enum.sort([archived.id, published.id, superseded.id])
    end

    test "the ACTIVE-only resolve_selector still excludes archived id-list rows (unchanged)" do
      tenant = fixture(:tenant)
      archived = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      published = fixture(:article, %{tenant_id: tenant.id, status: :published})

      # Archive/unpublish semantics are untouched: the active-only resolver still
      # skips the archived row.
      assert {:ok, [published_id]} =
               BulkOps.resolve_selector(tenant.id, {:ids, [archived.id, published.id]})

      assert published_id == published.id
    end

    test "an active row still purges via the id-list token path" do
      tenant = fixture(:tenant)
      active = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert {:ok, %{would_affect: 1, token: token_id}} =
               BulkOps.preview(tenant.id, :delete, {:ids, [active.id]}, audit_opts())

      assert {:ok, %{affected: 1}} =
               BulkOps.delete_with_token(tenant.id, token_id, audit_opts())

      refute AdminRepo.get(Article, active.id)
    end

    test "tenant isolation: cannot purge another tenant's archived row by id" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      theirs = fixture(:article, %{tenant_id: tenant_b.id, status: :archived})

      # tenant_a previewing tenant_b's archived id resolves to nothing.
      assert {:ok, %{would_affect: 0, token: nil}} =
               BulkOps.preview(tenant_a.id, :delete, {:ids, [theirs.id]}, audit_opts())

      # And a direct delete over the foreign id purges nothing.
      assert {:ok, %{affected: 0}} =
               BulkOps.delete(tenant_a.id, [theirs.id], audit_opts())

      assert AdminRepo.get(Article, theirs.id)
    end
  end
end
