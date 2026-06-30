defmodule Loopctl.Workers.KnowledgeMocWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Workers.KnowledgeMocWorker

  # min_tag_count is 2 in config/test.exs.

  defp published(tenant_id, title, tags, category \\ :pattern) do
    fixture(:article, %{
      tenant_id: tenant_id,
      title: title,
      body: "Body for #{title}.",
      category: category,
      tags: tags
    })
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp moc_hub(tenant_id, tag) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: fragment("? = ?", a.idempotency_key, ^"moc:#{tag}")
    )
    |> AdminRepo.one()
  end

  defp run(tenant_id),
    do: KnowledgeMocWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant_id}})

  describe "per-tenant MOC generation" do
    test "builds an index hub for a tag at/above the threshold, grouped by category" do
      tenant = fixture(:tenant)
      published(tenant.id, "Supervisors 101", ["elixir"], :pattern)
      published(tenant.id, "GenServer pitfalls", ["elixir"], :finding)
      published(tenant.id, "Deploy steps", ["elixir"], :playbook)

      assert :ok = run(tenant.id)

      hub = moc_hub(tenant.id, "elixir")
      assert hub
      assert hub.title == "Index: elixir"
      assert hub.category == :reference
      assert hub.status == :published
      assert "hub" in hub.tags and "moc" in hub.tags and "elixir" in hub.tags

      # Mechanical, grouped-by-category body that lists the members.
      assert hub.body =~ "Map of content for the **elixir**"
      assert hub.body =~ "## pattern"
      assert hub.body =~ "## finding"
      assert hub.body =~ "## playbook"
      assert hub.body =~ "Supervisors 101"
      assert hub.body =~ "GenServer pitfalls"
    end

    test "does not build a MOC for a tag below the threshold" do
      tenant = fixture(:tenant)
      published(tenant.id, "Lonely note", ["rare-tag"], :pattern)

      assert :ok = run(tenant.id)
      refute moc_hub(tenant.id, "rare-tag")
    end

    test "is idempotent and refreshes the body — re-run updates, never duplicates" do
      tenant = fixture(:tenant)
      published(tenant.id, "First", ["topic"])
      published(tenant.id, "Second", ["topic"])

      assert :ok = run(tenant.id)
      hub1 = moc_hub(tenant.id, "topic")
      refute hub1.body =~ "Third"

      # Corpus grows, then re-run.
      published(tenant.id, "Third", ["topic"])
      assert :ok = run(tenant.id)

      # Same hub (no duplicate), body now includes the new member.
      count =
        from(a in Article,
          where: a.tenant_id == ^tenant.id,
          where: fragment("? = ?", a.idempotency_key, ^"moc:topic")
        )
        |> AdminRepo.aggregate(:count)

      assert count == 1
      hub2 = moc_hub(tenant.id, "topic")
      assert hub2.id == hub1.id
      assert hub2.body =~ "Third"
    end

    test "does not list MOC hubs inside other MOCs" do
      tenant = fixture(:tenant)
      published(tenant.id, "A", ["topic"])
      published(tenant.id, "B", ["topic"])
      assert :ok = run(tenant.id)

      # The hub carries the "topic" tag, so a naive re-run could list itself.
      assert :ok = run(tenant.id)
      hub = moc_hub(tenant.id, "topic")
      refute hub.body =~ "Index: topic\n- "
      refute hub.body =~ "Index: topic — `"
    end

    test "indexes only topical tags — excludes structural/format and provenance-prefix tags" do
      tenant = fixture(:tenant)

      for n <- 1..3 do
        published(tenant.id, "Doc #{n}", ["pdf"])
        published(tenant.id, "Vid #{n}", ["yt-abc123"])
        published(tenant.id, "Rust #{n}", ["rust"])
      end

      assert :ok = run(tenant.id)

      # `pdf` (structural) and `yt-abc123` (per-source provenance) get no MOC...
      refute moc_hub(tenant.id, "pdf")
      refute moc_hub(tenant.id, "yt-abc123")
      # ...but a genuine topic does.
      assert moc_hub(tenant.id, "rust")
    end
  end

  describe "all_tenants fan-out" do
    test "generates MOCs for each active tenant, skipping suspended" do
      active = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})
      published(active.id, "X", ["shared"])
      published(active.id, "Y", ["shared"])
      published(suspended.id, "Z1", ["shared"])
      published(suspended.id, "Z2", ["shared"])

      assert :ok = KnowledgeMocWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

      assert moc_hub(active.id, "shared")
      refute moc_hub(suspended.id, "shared")
    end
  end

  describe "tenant isolation" do
    test "a MOC only indexes the caller tenant's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      published(tenant_a.id, "A-only", ["dom"])
      published(tenant_a.id, "A-two", ["dom"])
      published(tenant_b.id, "B-secret", ["dom"])

      assert :ok = run(tenant_a.id)

      hub = moc_hub(tenant_a.id, "dom")
      assert hub.body =~ "A-only"
      refute hub.body =~ "B-secret"
      refute moc_hub(tenant_b.id, "dom")
    end
  end
end
