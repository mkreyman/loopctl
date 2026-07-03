defmodule Loopctl.Workers.KnowledgeReclassifyWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article
  alias Loopctl.Workers.KnowledgeReclassifyWorker

  # Published article via the proven create-then-publish path (status transitions
  # are applied after creation, mirroring the other knowledge-worker tests).
  defp published(tenant_id, category) do
    fixture(:article, %{
      tenant_id: tenant_id,
      category: category,
      title: "Article #{System.unique_integer([:positive])}",
      body: "Body content."
    })
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp reload(id), do: AdminRepo.get!(Article, id)

  # Mandatory BYO (Epic 28, #179): the reclassify worker skips a tenant with no
  # Anthropic key. Every reclassify test needs a keyed tenant.
  defp tenant_with_key do
    t = fixture(:tenant, %{})
    fixture(:tenant_llm_settings, %{tenant_id: t.id})
    t
  end

  defp verdict(category, confidence) do
    Mox.stub(Loopctl.MockCategoryClassifier, :classify, fn _tenant_id, _title, _body, _opts ->
      {:ok, %{category: category, confidence: confidence}}
    end)
  end

  defp reclassify_audits(tenant_id) do
    from(a in AuditLog,
      where: a.tenant_id == ^tenant_id,
      where: a.action == "knowledge.reclassify_batch",
      order_by: [asc: a.inserted_at]
    )
    |> AdminRepo.all()
  end

  defp run(tenant_id, extra_args) do
    args = Map.merge(%{"tenant_id" => tenant_id}, extra_args)
    KnowledgeReclassifyWorker.perform(%Oban.Job{args: args})
  end

  describe "dry_run mode" do
    test "classifies but writes nothing; audit tallies what would change" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)
      b = published(tenant.id, :pattern)
      verdict(:playbook, 0.9)

      assert :ok = run(tenant.id, %{"run_mode" => "dry_run"})

      # No writes in dry-run.
      assert reload(a.id).category == :convention
      assert reload(b.id).category == :pattern

      assert [entry] = reclassify_audits(tenant.id)
      assert entry.new_state["run_mode"] == "dry_run"
      assert entry.new_state["batch"]["changed"] == 2
      assert entry.new_state["batch"]["by_transition"]["convention->playbook"] == 1
      assert entry.new_state["batch"]["by_transition"]["pattern->playbook"] == 1
    end
  end

  describe "commit mode write-on-confident-change" do
    test "rewrites category and records provenance when confident and different" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)
      verdict(:playbook, 0.9)

      assert :ok = run(tenant.id, %{"run_mode" => "commit"})

      reloaded = reload(a.id)
      assert reloaded.category == :playbook
      assert reloaded.metadata["reclassified_from"] == "convention"
      assert reloaded.metadata["reclassify_confidence"] == 0.9
    end

    test "leaves the article alone when confidence is below threshold" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)
      verdict(:playbook, 0.5)

      assert :ok = run(tenant.id, %{"run_mode" => "commit", "min_confidence" => 0.75})

      assert reload(a.id).category == :convention
      assert [entry] = reclassify_audits(tenant.id)
      assert entry.new_state["batch"]["low_confidence"] == 1
      assert entry.new_state["batch"]["changed"] == 0
    end

    test "no-op when the proposed category equals the current one" do
      tenant = tenant_with_key()
      a = published(tenant.id, :pattern)
      verdict(:pattern, 0.99)

      assert :ok = run(tenant.id, %{"run_mode" => "commit"})

      assert reload(a.id).category == :pattern
      assert [entry] = reclassify_audits(tenant.id)
      assert entry.new_state["batch"]["unchanged"] == 1
      assert entry.new_state["batch"]["changed"] == 0
    end

    test "always moves a retired convention row off convention when confident" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)
      verdict(:insight, 0.8)

      assert :ok = run(tenant.id, %{"run_mode" => "commit"})

      assert reload(a.id).category == :insight
    end

    test "a few errored classifications (below the snooze rate) leave those articles alone but proceed" do
      tenant = tenant_with_key()
      # 3 articles: one errors (33% < 50% snooze rate), two classify fine.
      bad = published(tenant.id, :convention)
      good_a = published(tenant.id, :convention)
      good_b = published(tenant.id, :convention)

      Mox.stub(Loopctl.MockCategoryClassifier, :classify, fn _tenant_id, title, _body, _opts ->
        if title == bad.title,
          do: {:error, :unparseable_classification},
          else: {:ok, %{category: :playbook, confidence: 0.9}}
      end)

      assert :ok = run(tenant.id, %{"run_mode" => "commit"})

      assert reload(bad.id).category == :convention
      assert reload(good_a.id).category == :playbook
      assert reload(good_b.id).category == :playbook
      assert [entry] = reclassify_audits(tenant.id)
      assert entry.new_state["batch"]["errors"] == 1
      assert entry.new_state["batch"]["changed"] == 2
    end
  end

  describe "outage resilience" do
    test "snoozes and retries the same cursor when the whole batch fails (upstream down)" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)

      # Every classify errors -> 100% error rate -> upstream is unreachable.
      Mox.stub(Loopctl.MockCategoryClassifier, :classify, fn _tenant_id, _t, _b, _opts ->
        {:error, :econnrefused}
      end)

      assert {:snooze, seconds} = run(tenant.id, %{"run_mode" => "commit"})
      assert is_integer(seconds) and seconds > 0

      # Nothing written and NO audit/advance — it will retry the same cursor.
      assert reload(a.id).category == :convention
      assert [] == reclassify_audits(tenant.id)
    end
  end

  describe "cost ceiling + batch chaining" do
    test "stops after max_per_run, leaving the remainder for the next kick" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)
      b = published(tenant.id, :convention)
      c = published(tenant.id, :convention)
      verdict(:playbook, 0.9)

      # batch_size 1 forces chaining; max_per_run 2 stops after two articles.
      assert :ok =
               run(tenant.id, %{
                 "run_mode" => "commit",
                 "batch_size" => 1,
                 "max_per_run" => 2
               })

      categories = Enum.map([a, b, c], &reload(&1.id).category)
      assert Enum.count(categories, &(&1 == :playbook)) == 2
      assert Enum.count(categories, &(&1 == :convention)) == 1
    end
  end

  describe "all_tenants fan-out" do
    test "reclassifies each active tenant, skipping suspended ones" do
      active_a = tenant_with_key()
      active_b = tenant_with_key()
      suspended = fixture(:tenant, %{status: :suspended})

      a = published(active_a.id, :convention)
      b = published(active_b.id, :convention)
      s = published(suspended.id, :convention)
      verdict(:playbook, 0.9)

      assert :ok =
               KnowledgeReclassifyWorker.perform(%Oban.Job{
                 args: %{"mode" => "all_tenants", "run_mode" => "commit"}
               })

      assert reload(a.id).category == :playbook
      assert reload(b.id).category == :playbook
      assert reload(s.id).category == :convention
    end
  end

  describe "tenant isolation" do
    test "only the caller tenant's articles are touched" do
      tenant_a = tenant_with_key()
      tenant_b = tenant_with_key()
      a = published(tenant_a.id, :convention)
      b = published(tenant_b.id, :convention)
      verdict(:playbook, 0.9)

      assert :ok = run(tenant_a.id, %{"run_mode" => "commit"})

      assert reload(a.id).category == :playbook
      assert reload(b.id).category == :convention
      assert [] == reclassify_audits(tenant_b.id)
    end
  end

  describe "mandatory BYO (Epic 28, #179)" do
    test "skips a tenant with no Anthropic key; the classifier is never called (review #8)" do
      # A tenant WITHOUT an llm settings row (no key configured).
      tenant = fixture(:tenant)
      a = published(tenant.id, :convention)

      expect(Loopctl.MockCategoryClassifier, :classify, 0, fn _t, _ti, _b, _o ->
        flunk("classifier must not run without a tenant key")
      end)

      assert :ok = run(tenant.id, %{"run_mode" => "commit"})
      # Nothing changed, no audit (no work done).
      assert reload(a.id).category == :convention
      assert [] == reclassify_audits(tenant.id)
    end

    test "a batch of PERMANENT classify errors advances without snoozing forever (review #4)" do
      tenant = tenant_with_key()
      a = published(tenant.id, :convention)

      # A 401 (bad key) is a PERMANENT error — a retry can't fix it, so the worker
      # must NOT snooze (which would loop every 60s forever); it advances instead.
      Mox.stub(Loopctl.MockCategoryClassifier, :classify, fn _t, _ti, _b, _o ->
        {:error, {:api_error, 401, %{}}}
      end)

      assert :ok = run(tenant.id, %{"run_mode" => "commit"})

      # Article left unchanged, but the batch is audited (advanced, not paused).
      assert reload(a.id).category == :convention
      assert [entry] = reclassify_audits(tenant.id)
      assert entry.new_state["batch"]["permanent_errors"] == 1
      assert entry.new_state["batch"]["transient_errors"] == 0
    end
  end
end
