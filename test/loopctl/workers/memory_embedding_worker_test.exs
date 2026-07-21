defmodule Loopctl.Workers.MemoryEmbeddingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Custody
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.ObanConfig
  alias Loopctl.Test.AllowlistSource
  alias Loopctl.Workers.MemoryEmbeddingWorker

  defp job(memory_id, tenant_id) do
    %Oban.Job{args: %{"memory_id" => memory_id, "tenant_id" => tenant_id}}
  end

  # Seed a raw executing oban_jobs row (no RLS on oban_jobs → AdminRepo) to occupy a
  # tenant's :embeddings slot, exactly as FairShare counts it. Direct insert does NOT
  # run the job (unlike Oban.insert under :inline).
  defp seed_executing_embedding(tenant_id, worker) do
    %{"tenant_id" => tenant_id}
    |> Oban.Job.new(worker: worker, queue: "embeddings")
    |> Ecto.Changeset.put_change(:state, "executing")
    |> AdminRepo.insert!()
  end

  describe "perform/1 success" do
    test "generates and stores the embedding + content hash for a memory" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "a durable fact"})
      assert is_nil(memory.embedding)

      embedding = List.duplicate(0.3, 1536)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
        assert text =~ "a durable fact"
        {:ok, embedding}
      end)

      assert :ok = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))

      {:ok, reloaded} = Memory.get_memory_for_embedding(tenant.id, memory.id)
      refute is_nil(reloaded.embedding)
      assert is_binary(reloaded.embedding_content_hash)
    end
  end

  # US-41.7 review: the embed's custody posture was recorded under a TENANT-ONLY
  # egress scope while both memory create paths assign theirs with
  # `EgressScope.new(tenant_id, project_id)`. Since `Egress.effective_local_only?/1`
  # matches only the tenant-wide marking when project_id is nil, a project-scoped
  # `local_only` memory got a claimable CREATE and a silently unrecorded EMBED —
  # i.e. a COMPLETE, zero-egress claim for a body that was POSTed to the provider.
  describe "custody scope follows the memory's own project (US-41.7)" do
    test "a PROJECT-scoped local_only memory records its embed" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      project = fixture(:project, %{tenant_id: tenant.id})

      AllowlistSource.put(["api.openai.com", "api.anthropic.com"])
      on_exit(fn -> AllowlistSource.clear() end)

      {:ok, _} = Egress.enable_local_only(tenant.id, project.id, acknowledge: true)
      PinCache.invalidate_tenant(tenant.id)

      memory =
        fixture(:memory, %{
          tenant_id: tenant.id,
          subject_id: "s",
          project_id: project.id,
          text: "a project fact"
        })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.3, 1536)}
      end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
      end)

      assert [entry] = Custody.list_entries(tenant.id, "memory", memory.id)
      assert entry.operation == "embed"
      assert entry.posture["scope"] == "tenant:#{tenant.id}/project:#{project.id}"
    end
  end

  # --- US-36.2: per-tenant fair-share gate on the contended :embeddings queue ---
  #
  # :embeddings has TWO tenant-scoped per-item fan-out producers — this worker AND
  # ArticleEmbeddingWorker — and the gate counts executing slots by (queue, state,
  # tenant) regardless of worker. So this worker MUST gate too, else a one-tenant
  # memory-embed burst monopolizes the queue against BOTH producers.
  describe "perform/1 fair-share gate (US-36.2)" do
    test "snoozes (loss-free) when the tenant is at/above its :embeddings fair share" do
      tenant = fixture(:tenant)
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)

      # `cap` of the tenant's embedding jobs are already executing (lower ids)...
      for _ <- 1..cap do
        seed_executing_embedding(tenant.id, "Loopctl.Workers.ArticleEmbeddingWorker")
      end

      # ...so THIS memory-embed job (higher id → rank cap >= cap) is over its fair share.
      # It must snooze at the TOP of perform/1 — no provider call, no memory fetch.
      this_job = seed_executing_embedding(tenant.id, "Loopctl.Workers.MemoryEmbeddingWorker")

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _t, _text ->
        flunk("provider must not be called when the fair-share gate snoozes")
      end)

      assert {:snooze, _n} =
               MemoryEmbeddingWorker.perform(%Oban.Job{
                 id: this_job.id,
                 args: %{"memory_id" => Ecto.UUID.generate(), "tenant_id" => tenant.id}
               })
    end

    test "runs (embeds) when the tenant is under its :embeddings fair share" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "under cap"})

      # No other executing embedding jobs for this tenant → rank 0 < cap → gate passes.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, List.duplicate(0.2, 1536)}
      end)

      assert :ok =
               MemoryEmbeddingWorker.perform(%Oban.Job{
                 id: 1,
                 args: %{"memory_id" => memory.id, "tenant_id" => tenant.id}
               })

      {:ok, reloaded} = Memory.get_memory_for_embedding(tenant.id, memory.id)
      refute is_nil(reloaded.embedding)
    end
  end

  # --- TC-28.2.7: idempotency (content-hash short-circuit) ---

  describe "perform/1 idempotency" do
    test "embeds exactly once across two runs with unchanged text" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "unchanging"})

      # EXACTLY ONE provider call across both runs.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 1, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      assert :ok = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))

      {:ok, after_first} = Memory.get_memory_for_embedding(tenant.id, memory.id)
      hash1 = after_first.embedding_content_hash

      # Second run: content hash matches → no embed call (short-circuit).
      assert :ok = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))

      {:ok, after_second} = Memory.get_memory_for_embedding(tenant.id, memory.id)
      assert after_second.embedding_content_hash == hash1
    end
  end

  describe "perform/1 error handling" do
    test "a deleted memory is a no-op" do
      tenant = fixture(:tenant)
      assert :ok = MemoryEmbeddingWorker.perform(job(Ecto.UUID.generate(), tenant.id))
    end

    test "no embedding key -> {:discard, {:no_embedding_key, _}} (mandatory BYO)" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "keyless"})

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :no_api_key}
      end)

      assert {:discard, {:no_embedding_key, _}} =
               MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
    end

    test "a permanent provider 4xx -> {:discard, {:embedding_permanent_error, _}}" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "bad key"})

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, {:api_error, 401, "unauthorized"}}
      end)

      assert {:discard, {:embedding_permanent_error, _}} =
               MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
    end

    test "a transient provider 5xx -> {:error, _} for retry" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "upstream boom"})

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, {:api_error, 500, "boom"}}
      end)

      assert {:error, _} = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
    end

    test "US-37.1 (AC-37.1.4): a node-local rate-limit snoozes (never discards)" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "rate limited"})

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :rate_limited_local}
      end)

      assert {:snooze, seconds} = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
      assert is_integer(seconds) and seconds > 0
    end

    test "US-37.3 (AC-37.3.3): a throttle 429 with a Retry-After snoozes ~that interval" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "throttled"})

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, {:api_error, 429, :provider_error, 30}}
      end)

      # Loss-free snooze for the provider Retry-After (no attempt consumed), NOT the
      # polynomial backoff and NOT a discard.
      assert {:snooze, 30} = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
    end

    test "US-37.3 (AC-37.3.5): an OPEN breaker snoozes (loss-free), never calling the provider" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      memory = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "breaker open"})

      # Trip the tenant breaker with @failure_threshold (3) countable 429 failures.
      # `stub` (not an exact `expect`) deliberately avoids the Mox async-supervisor
      # $callers exact-count race — the embed runs in a Task under async_nolink.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, {:api_error, 429, :provider_error}}
      end)

      for _ <- 1..3, do: Knowledge.generate_embedding(tenant.id, "x")
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "x")

      # Breaker OPEN → loss-free snooze (no attempt consumed), NOT {:error, ...} —
      # which under a long honored cooldown would discard the job and leave the memory
      # permanently un-embedded. The provider is never hit: generate_embedding
      # short-circuits on the OPEN breaker (deterministic ETS state) BEFORE spawning
      # the embed task.
      assert {:snooze, seconds} = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
      assert is_integer(seconds) and seconds > 0
    end

    test "US-37.2 (AC-37.2.2): the SAME per-node concurrency cap gates the worker (snooze, client never called)" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      memory =
        fixture(:memory, %{tenant_id: tenant.id, subject_id: "s", text: "concurrency capped"})

      # The concurrency gate (SAME one the interactive path AND ArticleEmbeddingWorker
      # use) is saturated: this worker's generate_embedding -> run_embedding_task ->
      # acquire returns {:error, :rate_limited_local} BEFORE the paid embedding client
      # is ever reached. Asserting the client is NOT called (0 expectations) proves the
      # cap really gates the memory-worker path too, not just the query path — closing
      # AC-37.2.2's "both workers" coverage (mirrors the ArticleEmbeddingWorker test).
      Mox.stub(Loopctl.MockEmbeddingConcurrency, :acquire, fn _tenant_id ->
        {:error, :rate_limited_local}
      end)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _t, _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      # Loss-free backpressure: snooze (no attempt consumed), NEVER a discard.
      assert {:snooze, seconds} = MemoryEmbeddingWorker.perform(job(memory.id, tenant.id))
      assert is_integer(seconds) and seconds > 0
    end
  end
end
