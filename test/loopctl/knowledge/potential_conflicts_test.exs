defmodule Loopctl.Knowledge.PotentialConflictsTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink
  alias LoopctlWeb.ArticleJSON

  defp published(tenant_id, title) do
    fixture(:article, %{tenant_id: tenant_id, title: title, status: :published})
  end

  defp conflict_link(tenant_id, src, tgt, score) do
    %ArticleLink{tenant_id: tenant_id}
    |> ArticleLink.changeset(%{
      source_article_id: src.id,
      target_article_id: tgt.id,
      relationship_type: :potential_conflict,
      metadata: %{"auto_generated" => true, "similarity_score" => score}
    })
    |> AdminRepo.insert!()
  end

  describe "list_potential_conflicts/2" do
    test "returns flagged pairs, highest overlap first, with both articles" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "A")
      b = published(tenant.id, "B")
      c = published(tenant.id, "C")
      conflict_link(tenant.id, a, b, 0.94)
      conflict_link(tenant.id, a, c, 0.985)

      %{data: data, meta: meta} = Knowledge.list_potential_conflicts(tenant.id)

      assert meta.total_count == 2
      # Highest similarity first.
      assert [%{similarity: 0.985}, %{similarity: 0.94}] = data
      first = hd(data)
      titles = Enum.map(first.articles, & &1.title) |> Enum.sort()
      assert titles == ["A", "C"]
    end

    test "paginates with limit/offset" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "A")

      for n <- 1..3 do
        peer = published(tenant.id, "peer #{n}")
        conflict_link(tenant.id, a, peer, 0.9 + n / 100)
      end

      page = Knowledge.list_potential_conflicts(tenant.id, limit: 2, offset: 0)
      assert length(page.data) == 2
      assert page.meta.total_count == 3

      page2 = Knowledge.list_potential_conflicts(tenant.id, limit: 2, offset: 2)
      assert length(page2.data) == 1
    end

    test "is tenant-scoped" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      a1 = published(tenant_a.id, "A1")
      a2 = published(tenant_a.id, "A2")
      conflict_link(tenant_a.id, a1, a2, 0.95)

      assert %{meta: %{total_count: 0}, data: []} =
               Knowledge.list_potential_conflicts(tenant_b.id)
    end
  end

  describe "get_article surfaces potential_conflicts" do
    test "the JSON view flattens conflict links to the peer + similarity" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Main")
      peer = published(tenant.id, "Peer")
      conflict_link(tenant.id, a, peer, 0.96)

      {:ok, loaded} = Knowledge.get_article(tenant.id, a.id)
      json = ArticleJSON.article_data_with_links(loaded)

      assert [%{article_id: pid, title: "Peer", similarity: 0.96}] = json.potential_conflicts
      assert pid == peer.id
    end

    test "is an empty list when the article has no conflicts" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Solo")

      {:ok, loaded} = Knowledge.get_article(tenant.id, a.id)
      json = ArticleJSON.article_data_with_links(loaded)

      assert json.potential_conflicts == []
    end
  end

  describe "annotate_conflict/3 + executor" do
    setup do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Winner")
      b = published(tenant.id, "Loser")
      conflict_link(tenant.id, a, b, 0.95)
      %{tenant: tenant, a: a, b: b}
    end

    test "dismiss takes effect immediately and drops the pair from the queue", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert %{meta: %{total_count: 1}} = Knowledge.list_potential_conflicts(t.id)

      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "dismiss",
                   "classification" => "complementary"
                 },
                 actor_label: "agent:x"
               )

      assert res.disposition == :dismiss
      # Immediate.
      refute is_nil(res.executed_at)
      # Queue now excludes it.
      assert %{meta: %{total_count: 0}, data: []} = Knowledge.list_potential_conflicts(t.id)
    end

    test "supersede at high confidence is applied by the executor (loser retired)", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, res} =
               Knowledge.annotate_conflict(t.id, %{
                 "source_article_id" => b.id,
                 "target_article_id" => a.id,
                 "disposition" => "supersede",
                 "authoritative_article_id" => a.id,
                 "confidence" => "high"
               })

      # Deferred — not executed on record.
      assert is_nil(res.executed_at)
      # Loser still published until the executor runs.
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)

      # Loser retired; a supersedes link points winner -> loser.
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :superseded

      assert Loopctl.AdminRepo.get_by(ArticleLink,
               tenant_id: t.id,
               source_article_id: a.id,
               target_article_id: b.id,
               relationship_type: :supersedes
             )
    end

    test "supersede below high confidence is NOT auto-applied", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "medium"
        })

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published
    end

    test "last-write-wins: re-annotating the same pair (any order) upserts", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "dismiss"
        })

      # Re-annotate with the pair in the OTHER order and a different verdict.
      {:ok, res2} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => b.id,
          "target_article_id" => a.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "high"
        })

      assert res2.disposition == :supersede
      # Exactly one row for the pair.
      assert 1 ==
               Loopctl.AdminRepo.aggregate(
                 Loopctl.Knowledge.ConflictResolution,
                 :count,
                 :id
               )
    end

    test "get_article drops a resolved conflict from its surfaced conflicts", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, before} = Knowledge.get_article(t.id, a.id)
      assert [_] = ArticleJSON.article_data_with_links(before).potential_conflicts

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "dismiss"
        })

      {:ok, loaded} = Knowledge.get_article(t.id, a.id)
      assert ArticleJSON.article_data_with_links(loaded).potential_conflicts == []
    end

    test "requires the authoritative article for supersede", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:error, changeset} =
               Knowledge.annotate_conflict(t.id, %{
                 "source_article_id" => a.id,
                 "target_article_id" => b.id,
                 "disposition" => "supersede"
               })

      assert %{authoritative_article_id: _} = errors_on(changeset)
    end
  end
end
