defmodule Loopctl.Workers.MemoryGraduationSweepWorkerTest do
  @moduledoc """
  #411 Gap 3: the hourly cadence that graduates HOT long-term memories
  (`recall_count >= threshold`, not yet graduated) into durable knowledge articles via
  the novelty gate.

  Async: all writes route through `Loopctl.AdminRepo` (which points at the sandbox
  connection in test), and the novelty gate defaults to `:novel` (DataCase stub) so a
  candidate creates an article on the normal path unless a test overrides the assessor.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Workers.MemoryGraduationSweepWorker

  # A live memory with a set recall_count (recall_count is not castable — it is bumped
  # off the recall hot path — so we stamp it directly, mirroring a memory that has been
  # recalled `count` times).
  defp hot_memory(tenant_id, opts) do
    count = Keyword.get(opts, :recall_count, 5)

    memory =
      fixture(:memory,
        tenant_id: tenant_id,
        subject_id: Keyword.get(opts, :subject_id, "subj-#{System.unique_integer([:positive])}"),
        project_id: Keyword.get(opts, :project_id),
        text: Keyword.get(opts, :text, "durable fact #{System.unique_integer([:positive])}"),
        tags: Keyword.get(opts, :tags, [])
      )

    {_n, _} =
      from(m in MemorySchema, where: m.id == ^memory.id)
      |> AdminRepo.update_all(set: [recall_count: count])

    %{memory | recall_count: count}
  end

  defp articles_for(tenant_id) do
    from(a in Article, where: a.tenant_id == ^tenant_id) |> AdminRepo.all()
  end

  defp reload(memory), do: AdminRepo.get(MemorySchema, memory.id)

  describe "perform/1 — graduation of hot memories" do
    test "a hot, ungraduated memory is graduated into a knowledge article and stamped" do
      tenant = fixture(:tenant)
      memory = hot_memory(tenant.id, recall_count: 5, text: "the deploy runbook lives in ops")

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      assert [article] = articles_for(tenant.id)
      assert article.body == "the deploy runbook lives in ops"
      assert article.category == :finding
      assert article.project_id == nil
      assert article.metadata["source"] == "memory_graduation"
      assert article.metadata["graduated_from_memory_id"] == memory.id

      # The memory is stamped so a later sweep skips it.
      refute is_nil(reload(memory).graduated_at)
    end

    test "a below-threshold memory is NOT graduated" do
      tenant = fixture(:tenant)
      cold = hot_memory(tenant.id, recall_count: 1, text: "rarely recalled")

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      assert [] == articles_for(tenant.id)
      assert is_nil(reload(cold).graduated_at)
    end

    test "a project-scoped memory graduates to an article in the SAME project (no re-scope)" do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id)
      _m = hot_memory(tenant.id, recall_count: 4, project_id: project.id, text: "project fact")

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      assert [article] = articles_for(tenant.id)
      assert article.project_id == project.id
    end

    test "a second sweep does NOT re-graduate (graduated_at set) — no duplicate article" do
      tenant = fixture(:tenant)
      _m = hot_memory(tenant.id, recall_count: 5, text: "graduate once")

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})
      assert [_only] = articles_for(tenant.id)

      # Second tick: the memory is already stamped, so it is not even a candidate.
      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})
      assert length(articles_for(tenant.id)) == 1
    end

    test "novelty gate dedups a semantically-duplicate memory (verdict :duplicate) but still stamps it" do
      tenant = fixture(:tenant)
      _first = hot_memory(tenant.id, recall_count: 5, text: "the canonical durable fact")

      # First sweep creates the canonical article.
      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})
      assert [canonical] = articles_for(tenant.id)

      # A second hot memory whose content the gate judges a DUPLICATE of the canonical.
      dup = hot_memory(tenant.id, recall_count: 5, text: "the canonical durable fact (again)")

      Mox.stub(Loopctl.MockProposalAssessor, :assess, fn _tenant_id, _attrs, _opts ->
        %{
          verdict: :duplicate,
          score: 0.99,
          neighbors: [%{id: canonical.id, title: canonical.title, similarity_score: 0.99}]
        }
      end)

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      # No NEW article — the gate deduped — but the duplicate memory is still stamped
      # graduated so the sweep does not reprocess it forever.
      assert length(articles_for(tenant.id)) == 1
      refute is_nil(reload(dup).graduated_at)
    end
  end

  describe "perform/1 — tenant isolation + budget" do
    test "graduates within EACH tenant, attributing the article to the memory's own tenant" do
      t1 = fixture(:tenant)
      t2 = fixture(:tenant)
      _m1 = hot_memory(t1.id, recall_count: 5, text: "tenant one fact")
      _m2 = hot_memory(t2.id, recall_count: 5, text: "tenant two fact")

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      assert [a1] = articles_for(t1.id)
      assert [a2] = articles_for(t2.id)
      assert a1.body == "tenant one fact"
      assert a2.body == "tenant two fact"
    end

    test "the per-run execution budget caps the number graduated in one tick" do
      tenant = fixture(:tenant)
      _a = hot_memory(tenant.id, recall_count: 9, text: "hot A")
      _b = hot_memory(tenant.id, recall_count: 8, text: "hot B")

      prev = Application.get_env(:loopctl, :memory_graduation_max_per_run)
      Application.put_env(:loopctl, :memory_graduation_max_per_run, 1)
      on_exit(fn -> restore(:memory_graduation_max_per_run, prev) end)

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      # Exactly one graduated this run (the cap); the other remains for the next tick.
      assert length(articles_for(tenant.id)) == 1

      ungraduated =
        from(m in MemorySchema,
          where: m.tenant_id == ^tenant.id and is_nil(m.graduated_at)
        )
        |> AdminRepo.aggregate(:count, :id)

      assert ungraduated == 1
    end
  end

  defp restore(key, nil), do: Application.delete_env(:loopctl, key)
  defp restore(key, val), do: Application.put_env(:loopctl, key, val)
end
