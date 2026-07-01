defmodule Loopctl.Knowledge.KbCurationTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.KbCuration

  defp tenant_with_log(enabled?) do
    fixture(:tenant, %{settings: %{"kb_curation_log" => enabled?}})
  end

  describe "record/4 respects the per-tenant toggle" do
    test "records when kb_curation_log is on" do
      t = tenant_with_log(true)
      assert :ok = KbCuration.record(t.id, "supersede", "A retired for B", actor: "agent-1")

      %{data: [ev], meta: %{total_count: 1}} = KbCuration.list(t.id)
      assert ev.kind == "supersede"
      assert ev.summary == "A retired for B"
      assert ev.actor == "agent-1"
    end

    test "is a no-op when the toggle is off (default)" do
      off = tenant_with_log(false)
      default = fixture(:tenant)

      assert :ok = KbCuration.record(off.id, "supersede", "x", [])
      assert :ok = KbCuration.record(default.id, "supersede", "x", [])

      assert %{meta: %{total_count: 0}} = KbCuration.list(off.id)
      assert %{meta: %{total_count: 0}} = KbCuration.list(default.id)
    end

    test "nil tenant is a safe no-op" do
      assert :ok = KbCuration.record(nil, "supersede", "x", [])
    end
  end

  describe "enabled?/1" do
    test "reflects the tenant setting" do
      assert KbCuration.enabled?(tenant_with_log(true).id)
      refute KbCuration.enabled?(tenant_with_log(false).id)
      refute KbCuration.enabled?(fixture(:tenant).id)
    end
  end

  describe "list/2" do
    setup do
      t = tenant_with_log(true)
      KbCuration.record(t.id, "supersede", "s1", at: ~U[2026-06-10 10:00:00Z])
      KbCuration.record(t.id, "merge", "m1", at: ~U[2026-06-12 10:00:00Z])
      KbCuration.record(t.id, "supersede", "s2", at: ~U[2026-06-14 10:00:00Z])
      %{t: t}
    end

    test "most recent first", %{t: t} do
      assert ["s2", "m1", "s1"] = KbCuration.list(t.id).data |> Enum.map(& &1.summary)
    end

    test "filters by kind", %{t: t} do
      %{data: data, meta: %{total_count: 2}} = KbCuration.list(t.id, kind: "supersede")
      assert Enum.map(data, & &1.summary) == ["s2", "s1"]
    end

    test "filters by since (date)", %{t: t} do
      %{meta: %{total_count: 2}} = KbCuration.list(t.id, since: ~D[2026-06-12])
    end

    test "paginates", %{t: t} do
      assert length(KbCuration.list(t.id, limit: 2).data) == 2
      assert length(KbCuration.list(t.id, limit: 2, offset: 2).data) == 1
    end

    test "is tenant-scoped", %{t: t} do
      other = tenant_with_log(true)
      assert %{meta: %{total_count: 0}} = KbCuration.list(other.id)
      assert %{meta: %{total_count: 3}} = KbCuration.list(t.id)
    end
  end

  describe "integration — resolutions log when enabled" do
    alias Loopctl.AdminRepo
    alias Loopctl.Knowledge
    alias Loopctl.Knowledge.ArticleLink

    test "a supersede execution records a curation event" do
      t = tenant_with_log(true)
      a = fixture(:article, %{tenant_id: t.id, title: "Winner", status: :published})
      b = fixture(:article, %{tenant_id: t.id, title: "Loser", status: :published})

      %ArticleLink{tenant_id: t.id}
      |> ArticleLink.changeset(%{
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :potential_conflict,
        metadata: %{"similarity_score" => 0.98}
      })
      |> AdminRepo.insert!()

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "high"
        })

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)

      %{data: [ev]} = KbCuration.list(t.id, kind: "supersede")
      assert ev.summary =~ "Loser"
      assert ev.summary =~ "Winner"
      assert ev.confidence == "high"
    end

    test "a dismiss records a curation event" do
      t = tenant_with_log(true)
      a = fixture(:article, %{tenant_id: t.id, status: :published})
      b = fixture(:article, %{tenant_id: t.id, status: :published})

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "dismiss",
          "classification" => "complementary"
        })

      %{data: [ev], meta: %{total_count: 1}} = KbCuration.list(t.id, kind: "dismiss")
      assert ev.summary =~ "complementary"
    end
  end
end
