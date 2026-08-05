defmodule Loopctl.Memory.GraduationTest do
  @moduledoc """
  #411 Gap 3: recall-count tracking (off the recall hot path) and the explicit
  memory→knowledge graduation primitive (`Loopctl.Memory.graduate_memory/3`), including
  the local→global re-scope option.

  Async: recall routes through `Loopctl.HeavyRead` (AdminRepo in test) and all writes
  through `Loopctl.AdminRepo`, so everything shares the one sandbox connection. The
  recall-count bump runs in `:sync` mode in test (config/test.exs) so it executes inside
  the test process rather than a spawned task that would not see the sandbox.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema

  defp reload(memory), do: AdminRepo.get(MemorySchema, memory.id)

  describe "recall_count bump (off the hot path)" do
    test "a healthy semantic recall increments recall_count + last_recalled_at for returned rows" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)
      {:ok, target} = Memory.remember(scope, %{tier: :long_term, text: "the sky is blue today"})

      assert %{meta: %{fallback: false}} = Memory.recall(scope, query: "sky", limit: 5)

      reloaded = reload(target)
      assert reloaded.recall_count == 1
      refute is_nil(reloaded.last_recalled_at)

      # A second recall WITHIN the cooldown window does NOT bump: the dedup stops a tight
      # single-agent loop from inflating the hotness signal and gaming graduation.
      assert %{meta: %{fallback: false}} = Memory.recall(scope, query: "sky", limit: 5)
      assert reload(target).recall_count == 1

      # Once the cooldown has elapsed (simulated by ageing last_recalled_at past the
      # window), a fresh recall bumps again — genuine cross-window hotness accumulates.
      from(m in MemorySchema, where: m.id == ^target.id)
      |> AdminRepo.update_all(
        set: [last_recalled_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
      )

      assert %{meta: %{fallback: false}} = Memory.recall(scope, query: "sky", limit: 5)
      assert reload(target).recall_count == 2
    end

    test "the degraded ILIKE fallback path does NOT bump (hotness signal stays clean)" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)
      {:ok, target} = Memory.remember(scope, %{tier: :long_term, text: "the alamo is in texas"})

      # Force embedding generation to fail so recall takes the ILIKE fallback.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :circuit_open}
      end)

      assert %{results: [{_m, _} | _], meta: %{fallback: true}} =
               Memory.recall(scope, query: "alamo", limit: 5)

      assert reload(target).recall_count == 0
      assert is_nil(reload(target).last_recalled_at)
    end

    test "an include_superseded oversight read does NOT bump live memories' hotness" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)
      {:ok, target} = Memory.remember(scope, %{tier: :long_term, text: "oversight read fact"})

      assert %{meta: %{fallback: false}} =
               Memory.recall(scope, query: "oversight", limit: 5, include_superseded: true)

      assert reload(target).recall_count == 0
    end

    test "bump_recall_counts is best-effort: a bad id is swallowed, never raised" do
      scope = fixture(:memory_scope)
      assert :ok = Memory.bump_recall_counts(scope.tenant_id, ["not-a-uuid"])
      assert :ok = Memory.bump_recall_counts(scope.tenant_id, [])
    end
  end

  describe "graduate_memory/3 (explicit primitive + local→global re-scope)" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id)
      scope = fixture(:memory_scope, tenant_id: tenant.id, project_id: project.id)
      %{tenant: tenant, project: project, scope: scope}
    end

    test "graduates a memory into an article inheriting its project scope by default", %{
      scope: scope,
      project: project
    } do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "runbook: restart the worker pool"
        )

      assert {:ok, verdict, article} = Memory.graduate_memory(scope, memory.id)
      # `:gated_to_draft` is deliberately absent: graduation is an unattended writer and now
      # passes `on_low_novelty: :skip`, so it can never produce a draft. Leaving it in the
      # allowed set would let a regression back to the `:draft` default pass silently.
      assert verdict in [:created, :duplicate, :deduplicated]
      assert article.project_id == project.id
      assert article.body == "runbook: restart the worker pool"
      assert article.category == :finding
      refute is_nil(reload(memory).graduated_at)
    end

    test "a LOW-NOVELTY graduation creates nothing at all, rather than a stranded draft", %{
      scope: scope,
      project: project
    } do
      # Graduation is an UNATTENDED writer. The novelty gate's `:draft` default hands it a
      # queue with no consumer: publishing is orchestrator/user-gated and no worker calls it,
      # so a gated draft is invisible forever. `propose_article/3`'s own comment predicts
      # exactly this, and it was measured — 26 stranded drafts on the hosted corpus across
      # seven producing paths and zero automatic consumers.
      #
      # Skipping loses nothing a draft would have kept: low novelty MEANS a near-identical
      # article is already published, so the knowledge is in the corpus either way.
      expect(Loopctl.MockProposalAssessor, :assess, fn _tenant_id, _attrs, _opts ->
        %{verdict: :low_novelty, score: 0.91, neighbors: []}
      end)

      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "a near-duplicate of something already published"
        )

      before = AdminRepo.aggregate(Article, :count, :id)

      assert {:ok, :skipped_low_novelty, nil} = Memory.graduate_memory(scope, memory.id)

      assert AdminRepo.aggregate(Article, :count, :id) == before,
             "a low-novelty graduation must create NO article row — not even a draft"

      refute AdminRepo.exists?(from(a in Article, where: a.status == :draft)),
             "the whole point is that no draft is produced for an unattended writer"
    end

    test "re_scope: :global promotes a PROJECT memory to a tenant-wide (project_id nil) article",
         %{scope: scope, project: project} do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "this fact is tenant-wide worthy"
        )

      assert {:ok, _verdict, article} =
               Memory.graduate_memory(scope, memory.id, re_scope: :global)

      assert article.project_id == nil
    end

    test "re_scope: :global on an ALREADY-graduated memory refuses loudly (no silent wrong-scope success)",
         %{scope: scope, project: project, tenant: tenant} do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "worth globalizing after it proved itself in-project"
        )

      # First: default (project) graduation → a project-scoped article.
      assert {:ok, _v1, project_article} = Memory.graduate_memory(scope, memory.id)
      assert project_article.project_id == project.id

      # A memory has at most one graduated article (the (tenant_id, title) unique index),
      # so re_scope: :global on the now-graduated memory must NOT silently return the
      # project article as success — it refuses loudly, leaving the project article intact.
      assert {:error, :already_graduated} =
               Memory.graduate_memory(scope, memory.id, re_scope: :global)

      count =
        from(a in Article, where: a.tenant_id == ^tenant.id) |> AdminRepo.aggregate(:count, :id)

      assert count == 1
    end

    test "re_scope: :global works on a FIRST (ungraduated) graduation", %{
      scope: scope,
      project: project
    } do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "globalize me on first graduation"
        )

      assert {:ok, _v, article} = Memory.graduate_memory(scope, memory.id, re_scope: :global)
      assert article.project_id == nil
    end

    test "a fell-open novelty gate (embedding backend down) is NOT stamped and creates no article",
         %{scope: scope, project: project, tenant: tenant} do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "content the gate could not assess"
        )

      # The gate falls open with :unknown when the embedding backend is unavailable.
      Mox.stub(Loopctl.MockProposalAssessor, :assess, fn _tenant_id, _attrs, _opts ->
        %{verdict: :unknown, score: nil, neighbors: []}
      end)

      # Automated/graduation callers pass on_gate_unavailable: :skip, so a fell-open
      # assessment is a retryable error — no un-deduplicated article is injected and the
      # memory stays eligible (graduated_at NULL) for a later tick once embeddings recover.
      assert {:error, :gate_unavailable} = Memory.graduate_memory(scope, memory.id)
      assert is_nil(reload(memory).graduated_at)

      assert 0 ==
               from(a in Article, where: a.tenant_id == ^tenant.id)
               |> AdminRepo.aggregate(:count, :id)
    end

    test "a foreign (other-subject/tenant) memory id returns :not_found — no cross-subject oracle",
         %{scope: scope, project: project} do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          project_id: project.id,
          text: "owned by scope"
        )

      other = fixture(:memory_scope)
      assert {:error, :not_found} = Memory.graduate_memory(other, memory.id)
      # And it was not graduated by the failed cross-subject attempt.
      assert is_nil(reload(memory).graduated_at)
    end

    test "graduation article count is one per memory (idempotent re-graduation)", %{
      scope: scope,
      tenant: tenant
    } do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          text: "graduate me once"
        )

      assert {:ok, _v1, a1} = Memory.graduate_memory(scope, memory.id)
      assert {:ok, _v2, a2} = Memory.graduate_memory(scope, memory.id)
      assert a1.id == a2.id

      count =
        from(a in Article, where: a.tenant_id == ^tenant.id) |> AdminRepo.aggregate(:count, :id)

      assert count == 1
    end

    # #583: the graduation tag sanitizer is a declared MIRROR of the Article changeset's
    # tag rules, and the reserved idempotency namespace added a rule to that changeset.
    # If the mirror falls behind, the article insert fails, the structural-error branch
    # STAMPS the memory graduated, and the memory's one-shot graduation is consumed with
    # no article ever created — an unrecoverable silent loss.
    test "a memory carrying a malformed RESERVED tag still graduates (the tag is dropped, not the memory)",
         %{scope: scope, tenant: tenant} do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          text: "hot memory the extractor tagged with a reserved-looking topic",
          tags: ["idem-design", "elixir"]
        )

      assert {:ok, _verdict, article} = Memory.graduate_memory(scope, memory.id)
      assert "elixir" in article.tags
      refute "idem-design" in article.tags

      count =
        from(a in Article, where: a.tenant_id == ^tenant.id) |> AdminRepo.aggregate(:count, :id)

      assert count == 1
    end

    test "a WELL-FORMED reserved capture tag survives graduation (the capture identity is kept)",
         %{scope: scope} do
      memory =
        fixture(:memory,
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          text: "a memory that carries a real capture identity",
          tags: ["idem-url-7ebe1ca33431"]
        )

      assert {:ok, _verdict, article} = Memory.graduate_memory(scope, memory.id)
      assert "idem-url-7ebe1ca33431" in article.tags
    end
  end
end
