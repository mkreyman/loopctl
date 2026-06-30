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
end
