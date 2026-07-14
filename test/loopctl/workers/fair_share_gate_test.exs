defmodule Loopctl.Workers.FairShareGateTest do
  @moduledoc """
  US-36.2 — the per-tenant fair-share gate as exercised through the contended-queue
  workers themselves.

  Covers: a worker snoozes when its tenant is over fair share and runs after a drain
  (TC-36.2.2 / AC-36.2.2), the FAIRNESS OUTCOME CLASS — a flooding tenant does not
  starve another (TC-36.2.3 / AC-36.2.3), and the no-op-when-uncontended guarantee
  (TC-36.2.4 / AC-36.2.5). We assert outcome CLASSES (snooze vs runs), never an exact
  instantaneous slot count, per the async/inline-drain flake lesson.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.ObanConfig
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.PromotionEvalWorker

  # Simulate an occupied executing slot without running a job (a direct insert does
  # NOT trigger the inline test executor).
  defp seed_executing(tenant_id, queue, n) do
    for _ <- 1..n do
      %{"tenant_id" => tenant_id}
      |> Oban.Job.new(worker: "Loopctl.Workers.ArticleEmbeddingWorker", queue: to_string(queue))
      |> Ecto.Changeset.put_change(:state, "executing")
      |> AdminRepo.insert!()
    end
  end

  defp published_article(tenant_id) do
    # Create as :draft (avoids the inline embedding enqueue during create), then
    # flip to :published directly so perform/1 is tested in isolation.
    {:ok, article} =
      Knowledge.create_article(tenant_id, %{
        title: "Fair-share Article #{System.unique_integer([:positive])}",
        body: "Body for fair-share gate test.",
        category: :pattern,
        status: :draft
      })

    article
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp run_embedding(article_id, tenant_id, job_id \\ nil) do
    ArticleEmbeddingWorker.perform(%Oban.Job{
      id: job_id,
      args: %{"article_id" => article_id, "tenant_id" => tenant_id}
    })
  end

  # Seed the job-under-test's OWN row as `executing` (what the Basic engine commits
  # before dispatching perform/1) and return it, so the worker exercises the real
  # self-count path — not a detached %Oban.Job{} that is absent from the table.
  defp seed_self_executing(article_id, tenant_id) do
    %{"article_id" => article_id, "tenant_id" => tenant_id}
    |> Oban.Job.new(worker: "Loopctl.Workers.ArticleEmbeddingWorker", queue: "embeddings")
    |> Ecto.Changeset.put_change(:state, "executing")
    |> AdminRepo.insert!()
  end

  describe "TC-36.2.2 — worker snoozes when over fair share, then runs on drain" do
    test "returns {:snooze, n} (job not failed/discarded) and runs once under cap" do
      tenant = fixture(:tenant)
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)

      # Tenant is AT its cap of executing :embeddings slots.
      seed_executing(tenant.id, :embeddings, cap)
      article = published_article(tenant.id)

      # The gate yields the slot: a snooze reschedules WITHOUT consuming an attempt
      # and never fails/discards the job — fairness degrades to latency, not loss.
      assert {:snooze, n} = run_embedding(article.id, tenant.id)
      assert is_integer(n) and n > 0

      # Drain: the executing slots free up (simulate the queue moving on).
      AdminRepo.delete_all(from(j in "oban_jobs", where: j.state == "executing"))

      # Now under cap, the SAME job runs to completion (loss-free — it was never
      # dropped). One embedding client call for the real run.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      assert :ok = run_embedding(article.id, tenant.id)
      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert stored.embedding != nil
    end
  end

  describe "TC-36.2.4 — no snooze / no latency when uncontended (AC-36.2.5)" do
    test "an uncontended single-tenant job runs immediately without snoozing" do
      tenant = fixture(:tenant)
      article = published_article(tenant.id)

      # No executing slots seeded → the gate is a pure no-op.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.2, 1536)}
      end)

      assert :ok = run_embedding(article.id, tenant.id)
    end

    test "runs even when its OWN row is already `executing` (self-count must not gate)" do
      # Regression for the US-36.2 wedge: the Basic engine commits the job to
      # `executing` before perform/1, so it reads its OWN row. A single uncontended
      # job (its own row is the ONLY executing row) must still run, not snooze. On a
      # cap=1 queue this is the difference between working and a permanent wedge; here
      # on :embeddings it also proves the worker threads its job id into the gate.
      tenant = fixture(:tenant)
      article = published_article(tenant.id)
      self_job = seed_self_executing(article.id, tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.25, 1536)}
      end)

      # Without self-exclusion the worker would see 1 executing (itself) and, on any
      # cap=1 queue, snooze forever. With the fix its own row is excluded → runs.
      assert :ok = run_embedding(article.id, tenant.id, self_job.id)
      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert stored.embedding != nil
    end

    test "gets its FULL cap: cap-1 peers + its OWN executing row still runs (not cap-1)" do
      # Finding-3 regression: with self-counting, cap-1 real peers + the job itself =
      # cap → `cap >= cap` → snooze, so effective concurrency is cap-1. Excluding self
      # → cap-1 < cap → the cap-th job runs, giving the tenant its documented `cap`.
      tenant = fixture(:tenant)
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)
      article = published_article(tenant.id)

      # cap-1 OTHER executing peers for this tenant, plus the job's own executing row.
      seed_executing(tenant.id, :embeddings, cap - 1)
      self_job = seed_self_executing(article.id, tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.35, 1536)}
      end)

      assert :ok = run_embedding(article.id, tenant.id, self_job.id)
      {:ok, stored} = Knowledge.get_article_with_embedding(tenant.id, article.id)
      assert stored.embedding != nil
    end
  end

  describe "TC-36.2.3 — flooding tenant does not starve another (OUTCOME CLASS)" do
    test "tenant B makes progress while tenant A is over its fair share" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)

      # Tenant A floods the queue: at/over its fair share of executing slots.
      seed_executing(tenant_a.id, :embeddings, cap + 2)

      article_a = published_article(tenant_a.id)
      article_b = published_article(tenant_b.id)

      # A's next job YIELDS (snooze) — A cannot monopolize beyond its share...
      assert {:snooze, _} = run_embedding(article_a.id, tenant_a.id)

      # ...while B — whose OWN executing count is 0, well under cap — RUNS. B is not
      # stuck behind all of A's in-flight work (the fairness invariant that matters).
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.3, 1536)}
      end)

      assert :ok = run_embedding(article_b.id, tenant_b.id)
      {:ok, stored_b} = Knowledge.get_article_with_embedding(tenant_b.id, article_b.id)
      assert stored_b.embedding != nil
    end
  end

  describe "PromotionEvalWorker per-tenant clause is fair-share-gated (7th :knowledge worker)" do
    test "snoozes BEFORE any extraction LLM call when the tenant is over its :knowledge share" do
      # PromotionEvalWorker is the seventh tenant-scoped :knowledge worker; its per-tenant
      # clause runs a not-sub-second extraction LLM call. It must observe the same gate as
      # the other six. Over the tenant's :knowledge fair share, it yields {:snooze, n}
      # BEFORE PromotionEval.run — so no extraction expectation is set here; reaching
      # run_eval (an unstubbed LLM call) would raise and fail the test.
      tenant = fixture(:tenant)
      cap = ObanConfig.tenant_fair_share_cap(:knowledge)
      seed_executing(tenant.id, :knowledge, cap)

      assert {:snooze, n} =
               PromotionEvalWorker.perform(%Oban.Job{
                 id: nil,
                 args: %{"tenant_id" => tenant.id}
               })

      assert is_integer(n) and n > 0
    end
  end
end
