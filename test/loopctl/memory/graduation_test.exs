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
      assert verdict in [:created, :gated_to_draft, :duplicate, :deduplicated]
      assert article.project_id == project.id
      assert article.body == "runbook: restart the worker pool"
      assert article.category == :finding
      refute is_nil(reload(memory).graduated_at)
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
  end
end
