defmodule Mix.Tasks.Loopctl.ReserveIdempotencyTagsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Mix.Tasks.Loopctl.ReserveIdempotencyTags, as: Task

  @hex12 "7ebe1ca33431"

  defp tags_of(article), do: AdminRepo.get!(Article, article.id).tags

  setup do
    tenant = fixture(:tenant)
    {:ok, tenant: tenant}
  end

  describe "backfill/1" do
    test "dry run reports without writing", %{tenant: tenant} do
      article = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}"])

      report = Task.backfill(tenant: tenant.id, throttle: 0)

      assert report.changed == 1
      refute report.applied?
      assert tags_of(article) == ["url-#{@hex12}"]
    end

    test "--apply adds the reserved form alongside the legacy tag", %{tenant: tenant} do
      article = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}", "url-design"])

      assert %{changed: 1, applied?: true} =
               Task.backfill(apply: true, tenant: tenant.id, throttle: 0)

      assert tags_of(article) == ["url-#{@hex12}", "idem-url-#{@hex12}", "url-design"]
    end

    test "leaves genuine topical tags alone", %{tenant: tenant} do
      topical = ["url-design", "url-routing", "doc-string", "book-review", "elixir"]
      article = fixture(:article, tenant_id: tenant.id, tags: topical)

      assert %{changed: 0} = Task.backfill(apply: true, tenant: tenant.id, throttle: 0)
      assert tags_of(article) == topical
    end

    test "is idempotent — a second run changes nothing and never double-prefixes", %{
      tenant: tenant
    } do
      article = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}"])

      Task.backfill(apply: true, tenant: tenant.id, throttle: 0)
      after_first = tags_of(article)

      assert %{changed: 0} = Task.backfill(apply: true, tenant: tenant.id, throttle: 0)
      assert tags_of(article) == after_first
      refute Enum.any?(after_first, &String.contains?(&1, "idem-idem-"))
    end

    test "--drop-legacy removes the bare form on the second pass", %{tenant: tenant} do
      article = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}", "url-design"])

      Task.backfill(apply: true, tenant: tenant.id, throttle: 0)
      Task.backfill(apply: true, drop_legacy: true, tenant: tenant.id, throttle: 0)

      assert tags_of(article) == ["idem-url-#{@hex12}", "url-design"]
    end

    test "the promoted tags remain valid under the write guard", %{tenant: tenant} do
      article = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}"])
      Task.backfill(apply: true, tenant: tenant.id, throttle: 0)

      changeset = Article.update_changeset(article, %{tags: tags_of(article)})
      assert changeset.valid?
    end

    test "skips an article whose promotion would exceed the tag cap", %{tenant: tenant} do
      legacy =
        Enum.map(1..(Article.max_tags() - 1), &"url-#{String.pad_leading("#{&1}", 12, "0")}")

      article = fixture(:article, tenant_id: tenant.id, tags: legacy ++ ["elixir"])

      assert %{changed: 0, skipped_tag_cap: 1} =
               Task.backfill(apply: true, tenant: tenant.id, throttle: 0)

      assert tags_of(article) == legacy ++ ["elixir"]
    end

    test "pages through more articles than one batch", %{tenant: tenant} do
      articles =
        for i <- 1..5 do
          fixture(:article,
            tenant_id: tenant.id,
            tags: ["url-#{String.pad_leading("#{i}", 12, "0")}"]
          )
        end

      assert %{scanned: 5, changed: 5} =
               Task.backfill(apply: true, tenant: tenant.id, batch_size: 2, throttle: 0)

      for article <- articles do
        assert Enum.any?(tags_of(article), &String.starts_with?(&1, "idem-"))
      end
    end

    test "tenant isolation: --tenant never touches another tenant's articles", %{tenant: tenant} do
      other = fixture(:tenant)
      mine = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}"])
      theirs = fixture(:article, tenant_id: other.id, tags: ["url-#{@hex12}"])

      assert %{scanned: 1, changed: 1} =
               Task.backfill(apply: true, tenant: tenant.id, throttle: 0)

      assert "idem-url-#{@hex12}" in tags_of(mine)
      assert tags_of(theirs) == ["url-#{@hex12}"]
    end

    test "leaves a hex-shaped tag under an unknown family alone", %{tenant: tenant} do
      tags = ["commit-a94a8fe5ccb1", "release-202604150930", "elixir"]
      article = fixture(:article, tenant_id: tenant.id, tags: tags)

      assert %{changed: 0} =
               Task.backfill(apply: true, drop_legacy: true, tenant: tenant.id, throttle: 0)

      assert tags_of(article) == tags
    end

    test "a duplicated topical tag is neither counted nor rewritten", %{tenant: tenant} do
      dupes = ["elixir", "elixir", "ecto"]
      article = fixture(:article, tenant_id: tenant.id, tags: dupes)

      assert %{scanned: 1, changed: 0} =
               Task.backfill(apply: true, tenant: tenant.id, throttle: 0)

      assert tags_of(article) == dupes
    end
  end

  describe "run/1 argument validation" do
    # A discarded --tenant leaves the sweep unscoped, and the task runs on
    # AdminRepo (BYPASSRLS) where that predicate is the only scoping there is.
    test "a mistyped --tenant aborts instead of silently sweeping every tenant", %{
      tenant: tenant
    } do
      article = fixture(:article, tenant_id: tenant.id, tags: ["url-#{@hex12}"])

      assert_raise Mix.Error, ~r/--tenat/, fn ->
        Task.run(["--apply", "--tenat", tenant.id])
      end

      assert tags_of(article) == ["url-#{@hex12}"]
    end

    test "a leftover positional argument aborts" do
      assert_raise Mix.Error, ~r/deadbeef/, fn ->
        Task.run(["--apply", "deadbeef"])
      end
    end
  end
end
