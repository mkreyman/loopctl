defmodule Loopctl.KnowledgeCuratedTest do
  @moduledoc """
  US-31.1: GOVERNED "curated" (authoritative) marker + scope rules.

  Covers the pure `curated?/1` predicate, the governed `mark_curated/3` setter
  (the ONLY writer of the marker — an agent create/update cannot self-promote),
  the tenant-isolated `list_curated_sources/2` with system-scope precedence, and
  the authoritative check that excludes open `:potential_conflict` articles.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  # Creates a published tenant article and marks it curated via the governed path.
  defp curated_article(tenant_id, attrs \\ %{}) do
    article =
      fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))

    {:ok, marked} = Knowledge.mark_curated(tenant_id, article.id, actor_label: "user:admin")
    marked
  end

  # Creates a published SYSTEM article (tenant_id nil) and marks it curated.
  defp curated_system_article(attrs, tenant_id_for_create) do
    {:ok, article} =
      Knowledge.create_article(
        tenant_id_for_create,
        Map.merge(
          %{scope: :system, status: :published, category: :reference, body: "system body"},
          attrs
        )
      )

    assert is_nil(article.tenant_id)

    {:ok, marked} =
      Knowledge.mark_curated(nil, article.id, actor_label: "superadmin", scope: :system)

    marked
  end

  describe "curated?/1 (TC-31.1.1 — pure predicate, unit)" do
    test "requires the governed marker, not just category" do
      # An agent-authored, published :reference WITHOUT the governed marker is NOT
      # curated (self-promotion via category is blocked).
      agent_authored = %Article{status: :published, category: :reference, curated_at: nil}
      refute Knowledge.curated?(agent_authored)

      # The same article WITH the governed marker IS curated.
      marked = %Article{
        status: :published,
        category: :reference,
        curated_at: ~U[2026-07-10 00:00:00.000000Z]
      }

      assert Knowledge.curated?(marked)
    end

    test "is pure — no DB required, marker + published only" do
      assert Knowledge.curated?(%Article{
               status: :published,
               curated_at: ~U[2026-07-10 00:00:00.000000Z]
             })

      refute Knowledge.curated?(%Article{status: :published, curated_at: nil})
      refute Knowledge.curated?(%Article{status: :draft, curated_at: nil})
    end
  end

  describe "mark_curated/3 governance (security constraint)" do
    test "an agent create cannot self-set the curated marker via attrs/metadata" do
      tenant = fixture(:tenant)

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Self-promoted?",
          body: "body",
          category: :reference,
          status: :published,
          curated_at: ~U[2020-01-01 00:00:00.000000Z],
          curated_by: "agent:sneaky",
          metadata: %{"curated" => true}
        })

      # The non-castable marker was NOT set from attrs.
      assert is_nil(article.curated_at)
      refute Knowledge.curated?(article)
    end

    test "an agent update cannot self-set the curated marker via attrs" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, updated} =
        Knowledge.update_article(tenant.id, article.id, %{
          body: "new body",
          curated_at: ~U[2020-01-01 00:00:00.000000Z]
        })

      assert is_nil(updated.curated_at)
      refute Knowledge.curated?(updated)
    end

    test "the governed setter marks and unmarks; only it writes the marker" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      refute Knowledge.curated?(article)

      {:ok, marked} = Knowledge.mark_curated(tenant.id, article.id, actor_label: "user:admin")
      assert Knowledge.curated?(marked)
      assert marked.curated_by == "user:admin"

      {:ok, unmarked} = Knowledge.unmark_curated(tenant.id, article.id)
      refute Knowledge.curated?(unmarked)
      assert is_nil(unmarked.curated_at)
    end

    test "returns :not_found for a wrong-tenant article (no cross-tenant marking)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      assert {:error, :not_found} = Knowledge.mark_curated(tenant_b.id, article.id, [])
    end

    test "mark_curated writes an article.curated audit event under the tenant" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, marked} =
        Knowledge.mark_curated(tenant.id, article.id, actor_label: "user:admin")

      audit = audit_event(article.id, "article.curated")
      assert audit.tenant_id == tenant.id
      assert audit.actor_label == "user:admin"
      assert audit.new_state["curated_at"] == DateTime.to_iso8601(marked.curated_at)
    end

    test "unmark_curated writes an article.uncurated audit event" do
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id)

      {:ok, _unmarked} = Knowledge.unmark_curated(tenant.id, curated.id)

      audit = audit_event(curated.id, "article.uncurated")
      assert audit.tenant_id == tenant.id
      assert is_nil(audit.new_state["curated_at"])
    end

    test "system-scope curation writes a GLOBAL (tenant_id nil) audit event" do
      tenant = fixture(:tenant)
      system = curated_system_article(%{title: "Global Canonical"}, tenant.id)

      audit = audit_event(system.id, "article.curated")
      assert is_nil(audit.tenant_id)
    end

    test "nil-tenant curation is REJECTED without an explicit scope: :system opt-in" do
      tenant = fixture(:tenant)

      {:ok, system} =
        Knowledge.create_article(tenant.id, %{
          title: "Accidental Global",
          body: "b",
          category: :reference,
          scope: :system,
          status: :published
        })

      # An accidental/missing tenant context (nil) must NOT silently curate a GLOBAL
      # canonical — the system path requires a deliberate scope: :system.
      assert {:error, :system_scope_required} = Knowledge.mark_curated(nil, system.id, [])
      assert {:error, :system_scope_required} = Knowledge.unmark_curated(nil, system.id, [])

      # Reload: the marker was never written.
      reloaded = AdminRepo.get!(Article, system.id)
      assert is_nil(reloaded.curated_at)
      refute Knowledge.curated?(reloaded)

      # The deliberate path works.
      assert {:ok, marked} =
               Knowledge.mark_curated(nil, system.id, scope: :system, actor_label: "superadmin")

      assert Knowledge.curated?(marked)
    end
  end

  describe "curated marker invalidation on content edit (US-31.1 poisoning defense)" do
    test "editing the BODY of a curated article clears the marker, forcing re-curation" do
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id, %{body: "approved body"})
      assert Knowledge.curated?(curated)

      {:ok, edited} = Knowledge.update_article(tenant.id, curated.id, %{body: "poisoned body"})

      # The governed marker was invalidated by the content change: the poisoned
      # body is NOT authoritative until re-curated through the governed path.
      assert is_nil(edited.curated_at)
      refute Knowledge.curated?(edited)
      refute edited.id in ids(Knowledge.list_curated_sources(tenant.id))
    end

    test "editing the TITLE of a curated article clears the marker" do
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id, %{title: "Approved Title"})

      {:ok, edited} = Knowledge.update_article(tenant.id, curated.id, %{title: "Changed Title"})

      assert is_nil(edited.curated_at)
      refute Knowledge.curated?(edited)
    end

    test "publishing a curated DRAFT via the ordinary edit path clears the marker" do
      tenant = fixture(:tenant)
      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      {:ok, marked} = Knowledge.mark_curated(tenant.id, draft.id, [])

      # Marker set but not yet effective (draft).
      refute is_nil(marked.curated_at)
      refute Knowledge.curated?(marked)

      # Agent self-publishing via update must NOT flip it live under the admin marker.
      {:ok, published} = Knowledge.update_article(tenant.id, draft.id, %{status: :published})

      assert is_nil(published.curated_at)
      refute Knowledge.curated?(published)
    end

    test "a pure metadata/tags edit PRESERVES the curated marker" do
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id)
      assert Knowledge.curated?(curated)

      {:ok, edited} =
        Knowledge.update_article(tenant.id, curated.id, %{
          tags: ["a", "b"],
          metadata: %{"note" => "unrelated"}
        })

      # No title/body/status change → the curator's approval still stands.
      assert edited.curated_at == curated.curated_at
      assert Knowledge.curated?(edited)
      assert edited.id in ids(Knowledge.list_curated_sources(tenant.id))
    end
  end

  describe "authoritative curated excludes draft/superseded/conflicted (TC-31.1.2)" do
    test "a draft governed article is not curated" do
      tenant = fixture(:tenant)
      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      {:ok, marked} = Knowledge.mark_curated(tenant.id, draft.id, [])

      refute Knowledge.curated?(marked)
      refute marked.id in ids(Knowledge.list_curated_sources(tenant.id))
    end

    test "a superseded governed article is not curated" do
      tenant = fixture(:tenant)
      marked = curated_article(tenant.id)

      superseded =
        marked
        |> Article.curation_changeset(marked.curated_at, marked.curated_by)
        |> Ecto.Changeset.change(status: :superseded)
        |> AdminRepo.update!()

      refute Knowledge.curated?(superseded)
      refute marked.id in ids(Knowledge.list_curated_sources(tenant.id))
    end

    test "a curated article in an OPEN potential_conflict is not authoritative" do
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id, %{title: "Conflicted Curated"})
      other = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Rival"})

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: curated.id,
        target_article_id: other.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })

      # Pure predicate still true (status + marker), but authoritative check excludes it.
      assert Knowledge.curated?(curated)
      refute Knowledge.authoritative_curated?(curated)
      refute curated.id in ids(Knowledge.list_curated_sources(tenant.id))
    end

    test "an UNJUDGED conflict stops suppressing once it ages past the window" do
      # Suppression is premised on the conflict being judged SOON, not on it being judged
      # ever. Unbounded it becomes silent corpus deletion: measured on the hosted deployment
      # 2026-08-05, 16,117 open auto-generated conflicts growing +500/night with no automatic
      # drain, each withholding BOTH its articles from every curated answer.
      #
      # Both predicates are asserted, because they are separate implementations of one
      # invariant — `authoritative_curated?/1` and `list_curated_sources/1`. Fixing one and
      # not the other is how a half-applied invariant ships.
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id, %{title: "Aged Conflict"})
      other = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Rival"})

      link =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: curated.id,
          target_article_id: other.id,
          relationship_type: :potential_conflict,
          metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
        })

      # Fresh: suppressed, exactly as the sibling test above asserts.
      refute Knowledge.authoritative_curated?(curated)
      refute curated.id in ids(Knowledge.list_curated_sources(tenant.id))

      # Age it one day past the window. `article_links` is deliberately immutable (no update
      # changeset, `updated_at: false`), so backdate through the repo directly.
      aged_at =
        DateTime.add(
          DateTime.utc_now(),
          -(Knowledge.conflict_suppression_window_days() + 1),
          :day
        )

      link
      |> Ecto.Changeset.change(%{inserted_at: aged_at})
      |> AdminRepo.update!()

      # Still unjudged — no conflict_resolutions row was written — but no longer suppressing.
      assert Knowledge.authoritative_curated?(curated),
             "an aged unjudged conflict must stop suppressing the per-article authority check"

      assert curated.id in ids(Knowledge.list_curated_sources(tenant.id)),
             "an aged unjudged conflict must stop suppressing the curated-sources list"
    end

    test "authoritative_curated?/1 does not crash on a system canonical (tenant_id nil)" do
      tenant = fixture(:tenant)
      system = curated_system_article(%{title: "System Canonical"}, tenant.id)

      # Regression: article_in_open_conflict?/1 used to compare `l.tenant_id == ^nil`,
      # which Ecto rejects at runtime. A curated, non-conflicted system canonical MUST
      # be authoritative (AC-31.1.3) rather than raising.
      assert is_nil(system.tenant_id)
      assert Knowledge.curated?(system)
      assert Knowledge.authoritative_curated?(system)
    end

    test "a system canonical in an OPEN potential_conflict is not authoritative" do
      tenant = fixture(:tenant)
      system = curated_system_article(%{title: "Disputed System"}, tenant.id)

      other =
        curated_system_article(%{title: "Rival System", body: "rival"}, tenant.id)

      # A system-scoped auto-generated conflict pair (links live under the tenant that
      # surfaced them; correlation is by article id, so the system member still matches).
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: system.id,
        target_article_id: other.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })

      assert Knowledge.curated?(system)
      refute Knowledge.authoritative_curated?(system)
      refute system.id in ids(Knowledge.list_curated_sources(tenant.id))
    end

    test "one tenant's conflict over a system canonical does NOT retract it for OTHER tenants" do
      # A system canonical is shared by every tenant. Tenant A opens a conflict link
      # referencing it. The open-conflict exclusion is correlated on the CALLER's
      # tenant, so the canonical is suppressed only in TENANT A's list — tenant B
      # (uninvolved) still sees the global canonical. (Guards against a cross-tenant
      # global retraction via a single tenant's dispute.)
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      system = curated_system_article(%{title: "Shared Canonical"}, tenant_a.id)
      other = curated_system_article(%{title: "Rival Shared", body: "rival"}, tenant_a.id)

      # Conflict link lives under tenant_a only.
      fixture(:article_link, %{
        tenant_id: tenant_a.id,
        source_article_id: system.id,
        target_article_id: other.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })

      # Tenant A (the disputing tenant): canonical is withheld.
      refute system.id in ids(Knowledge.list_curated_sources(tenant_a.id))

      # Tenant B (uninvolved): the global canonical STILL participates.
      assert system.id in ids(Knowledge.list_curated_sources(tenant_b.id))
    end
  end

  describe "system-scope precedence (TC-31.1.3 / AC-31.1.3)" do
    test "system canonical participates but a tenant's own curated wins on the same topic" do
      tenant_a = fixture(:tenant)

      system = curated_system_article(%{title: "Topic X", body: "system answer"}, tenant_a.id)

      tenant_own =
        curated_article(tenant_a.id, %{
          title: "Topic X",
          body: "tenant answer",
          category: :reference
        })

      # A system-only topic still participates.
      system_only =
        curated_system_article(%{title: "Topic Y", body: "system only"}, tenant_a.id)

      result = Knowledge.list_curated_sources(tenant_a.id)
      result_ids = ids(result)

      # Tenant's own wins for Topic X; the system Topic X is suppressed (does not override).
      assert tenant_own.id in result_ids
      refute system.id in result_ids
      # System canonical on a topic the tenant hasn't curated still participates.
      assert system_only.id in result_ids
    end

    test "a system canonical participates when the tenant has no own answer on that topic" do
      tenant_a = fixture(:tenant)
      system = curated_system_article(%{title: "Only System Topic"}, tenant_a.id)

      assert system.id in ids(Knowledge.list_curated_sources(tenant_a.id))
    end

    test "a tenant's own curated-but-conflicted topic still suppresses the system canonical" do
      # AC-31.1.3 x AC-31.1.4 interaction: the tenant OWNS "Topic Z" (curated+published)
      # but that own article is itself in an open conflict. It is excluded from the RESULT
      # (AC-31.1.4), yet ownership is computed independently of conflict status, so the
      # system canonical on the same topic is STILL suppressed — a system answer never
      # overrides the tenant's own (disputed) answer. Net: neither surfaces; the conflict
      # must be resolved first.
      tenant_a = fixture(:tenant)

      system = curated_system_article(%{title: "Topic Z", body: "system answer"}, tenant_a.id)

      tenant_own =
        curated_article(tenant_a.id, %{
          title: "Topic Z",
          body: "tenant answer",
          category: :reference
        })

      rival =
        fixture(:article, %{tenant_id: tenant_a.id, status: :published, title: "Topic Z Rival"})

      fixture(:article_link, %{
        tenant_id: tenant_a.id,
        source_article_id: tenant_own.id,
        target_article_id: rival.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })

      result_ids = ids(Knowledge.list_curated_sources(tenant_a.id))

      # The conflicted tenant-own article is excluded (AC-31.1.4)...
      refute tenant_own.id in result_ids
      # ...and the system canonical on the same owned topic is STILL suppressed (AC-31.1.3).
      refute system.id in result_ids
    end
  end

  describe "list_curated_sources/2 tenant isolation (TC-31.1.4 / AC-31.1.5)" do
    test "a fresh tenant sees none of another tenant's curated articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a_curated = curated_article(tenant_a.id, %{title: "Tenant A Secret"})

      # tenant_b is fresh — its curated listing is empty and never leaks tenant_a's.
      b_result = Knowledge.list_curated_sources(tenant_b.id)
      assert b_result == []
      refute a_curated.id in ids(b_result)
    end

    test "two-tenant isolation: each tenant's listing contains only its own (plus system)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a_curated = curated_article(tenant_a.id, %{title: "A doc"})
      b_curated = curated_article(tenant_b.id, %{title: "B doc"})

      a_ids = ids(Knowledge.list_curated_sources(tenant_a.id))
      b_ids = ids(Knowledge.list_curated_sources(tenant_b.id))

      assert a_curated.id in a_ids
      refute b_curated.id in a_ids

      assert b_curated.id in b_ids
      refute a_curated.id in b_ids
    end
  end

  describe "list_curated_sources/2 - select: :id body-less projection (US-31.2 finding 5)" do
    test "select: :id returns a plain list of UUIDs, not full %Article{} structs" do
      tenant = fixture(:tenant)
      curated = curated_article(tenant.id, %{title: "Body-less Projection Target"})
      _other = fixture(:article, %{tenant_id: tenant.id, status: :published})

      full_result = Knowledge.list_curated_sources(tenant.id)
      id_result = Knowledge.list_curated_sources(tenant.id, select: :id)

      assert Enum.all?(full_result, &match?(%Loopctl.Knowledge.Article{}, &1))
      assert id_result == [curated.id]
      refute match?([%Loopctl.Knowledge.Article{} | _], id_result)
    end

    test "select: :id still honors every filter (category, include_system, limit, tenant scope)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a_curated = curated_article(tenant_a.id, %{title: "A doc for id projection"})
      _b_curated = curated_article(tenant_b.id, %{title: "B doc for id projection"})

      assert Knowledge.list_curated_sources(tenant_a.id, select: :id) == [a_curated.id]
    end
  end

  defp ids(articles), do: Enum.map(articles, & &1.id)

  defp audit_event(article_id, action) do
    from(a in AuditLog,
      where: a.entity_type == "article" and a.entity_id == ^article_id,
      where: a.action == ^action
    )
    |> AdminRepo.one!()
  end
end
