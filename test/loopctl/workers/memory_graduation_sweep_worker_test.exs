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

      # PUBLISHED (not draft) so it is discoverable by knowledge_search/context — the wiki
      # actually grows.
      assert article.status == :published

      # OWNER-visible, keyed to the memory's subject: subject-level isolation is preserved
      # (the private working memory is NOT exposed tenant-wide to peer agents).
      assert article.metadata["visibility"] == "owner"
      assert article.metadata["agent_id"] == memory.subject_id

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
      # SAME subject for both memories: a graduated article is OWNER-visible (subject-scoped),
      # so the gate can only dedup against an article the graduating subject can see. Two
      # memories from the SAME subject is the case the novelty gate must collapse to one
      # article (a distinct subject would — correctly — get its own owner-private copy rather
      # than leak/dedup across the subject-isolation boundary).
      subject_id = "subj-dedup-#{System.unique_integer([:positive])}"

      _first =
        hot_memory(tenant.id,
          recall_count: 5,
          subject_id: subject_id,
          text: "the canonical durable fact"
        )

      # First sweep creates the canonical article.
      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})
      assert [canonical] = articles_for(tenant.id)

      # A second hot memory (same subject) whose content the gate judges a DUPLICATE.
      dup =
        hot_memory(tenant.id,
          recall_count: 5,
          subject_id: subject_id,
          text: "the canonical durable fact (again)"
        )

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

    test "a memory with article-invalid tags still graduates (sanitized) — no per-slot livelock" do
      tenant = fixture(:tenant)

      # Memory tags are unvalidated at the memory tier; the Article changeset enforces
      # count/length/format. A verbatim copy would fail the changeset EVERY sweep (a
      # livelock re-spending embedding budget). These are all article-invalid: too many,
      # over-long, bad format, and non-binary — only "keeper" survives sanitization.
      bad_tags =
        [String.duplicate("x", 200), "has spaces", "bad!char", "keeper"] ++
          Enum.map(1..60, &"tag#{&1}")

      memory =
        hot_memory(tenant.id, recall_count: 5, text: "fact with hostile tags", tags: bad_tags)

      assert :ok = perform_job(MemoryGraduationSweepWorker, %{})

      assert [article] = articles_for(tenant.id)
      assert length(article.tags) <= 50
      assert "keeper" in article.tags
      refute "has spaces" in article.tags
      # Stamped, so the next tick does not re-attempt (and re-spend) forever.
      refute is_nil(reload(memory).graduated_at)
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

      # Cap this ONE tick to 1 via job args — async-safe (per-job, no VM-global mutation),
      # unlike the old `Application.put_env` which leaked into every concurrent test.
      assert :ok = perform_job(MemoryGraduationSweepWorker, %{"max_per_run" => 1})

      # Exactly one graduated this run (the cap); the other remains for the next tick.
      assert length(articles_for(tenant.id)) == 1

      ungraduated =
        from(m in MemorySchema,
          where: m.tenant_id == ^tenant.id and is_nil(m.graduated_at)
        )
        |> AdminRepo.aggregate(:count, :id)

      assert ungraduated == 1
    end

    test "per-tenant fairness: a hotter tenant cannot starve another tenant's graduation" do
      hot = fixture(:tenant)
      other = fixture(:tenant)

      # `hot` owns the two HOTTEST memories; `other` owns a cooler one. Under a naive
      # global hottest-first scan with a per-run budget of 2, `hot`'s two would consume the
      # whole budget and STARVE `other`. Round-robin across tenants must serve `other` too.
      _h1 = hot_memory(hot.id, recall_count: 9, text: "hot tenant fact A")
      _h2 = hot_memory(hot.id, recall_count: 8, text: "hot tenant fact B")
      cool = hot_memory(other.id, recall_count: 5, text: "other tenant fact")

      # Cap this ONE tick to 2 via job args (per-job, async-safe — no global mutation).
      assert :ok = perform_job(MemoryGraduationSweepWorker, %{"max_per_run" => 2})

      # The cooler tenant is graduated within the shared budget — not starved.
      refute is_nil(reload(cool).graduated_at)
      assert [_one] = articles_for(other.id)
    end
  end
end
