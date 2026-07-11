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
    {:ok, marked} = Knowledge.mark_curated(nil, article.id, actor_label: "superadmin")
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

  defp ids(articles), do: Enum.map(articles, & &1.id)
end
