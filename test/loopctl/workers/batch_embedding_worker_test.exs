defmodule Loopctl.Workers.BatchEmbeddingWorkerTest do
  @moduledoc """
  US-37.4: the per-tenant BATCH embedding worker drains a tenant's pending records
  in array batches of up to `embedding_batch_max` (~100), issuing
  `ceil(N / batch_max)` provider calls instead of N.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Workers.BatchEmbeddingWorker

  defp job(tenant_id, kind) do
    %Oban.Job{
      id: System.unique_integer([:positive]),
      args: %{"tenant_id" => tenant_id, "kind" => kind}
    }
  end

  # Insert N un-embedded long-term memories directly (no remember/2 → no inline
  # enqueue), one query.
  defp seed_memories(tenant_id, n) do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          subject_id: "subj",
          text: "durable fact number #{i}",
          confidence: 1.0,
          source: :explicit,
          tags: [],
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end

    {count, _} = AdminRepo.insert_all(MemorySchema, rows)
    count
  end

  # Deterministic 1536-dim vector seeded by the input text — lets a single-text
  # call and a batched call be compared for byte-identical vectors per index.
  defp det_vec(text) do
    base = :erlang.phash2(text, 100_000) / 100_000
    List.duplicate(base, 1536)
  end

  describe "AC-37.4.2: M records → ceil(M/batch_max) provider calls" do
    test "TC-37.4.2: 250 memories with batch_max=100 → exactly 3 array calls, not 250" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      assert 250 = seed_memories(tenant.id, 250)

      # EXACTLY 3 batched calls expected (ceil(250/100)); verify_on_exit! fails on
      # 250 (per-item) or any other count. Each call returns one vector per input.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 3, fn _tenant_id, texts ->
        assert length(texts) <= 100
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 1536) end)}
      end)

      assert :ok = BatchEmbeddingWorker.perform(job(tenant.id, "memory"))

      # Every memory got embedded — the pending set is drained.
      assert [] = Memory.list_memories_pending_embedding(tenant.id, 500)
    end
  end

  describe "AC-37.4.3: correctness — single vs batched vectors are identical per index" do
    test "TC-37.4.3: the guarded single and batch paths return the same vector per input" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      # Same deterministic function drives both the single and the batch stub.
      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
        {:ok, det_vec(text)}
      end)

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      texts = ["alpha fact", "beta fact", "gamma fact"]

      singles =
        Enum.map(texts, fn t ->
          {:ok, v} = Knowledge.generate_embedding(tenant.id, t)
          v
        end)

      assert {:ok, batched} = Knowledge.generate_embeddings(tenant.id, texts)

      # Equality PER INDEX (order preserved).
      assert batched == singles

      Enum.zip(batched, singles)
      |> Enum.each(fn {b, s} -> assert b == s end)
    end

    test "the worker stores a non-nil embedding for every drained memory" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      seed_memories(tenant.id, 3)

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      assert :ok = BatchEmbeddingWorker.perform(job(tenant.id, "memory"))

      memories = AdminRepo.all(MemorySchema)

      assert length(memories) == 3

      Enum.each(memories, fn m ->
        {:ok, reloaded} = Memory.get_memory_for_embedding(tenant.id, m.id)
        refute is_nil(reloaded.embedding)
        assert is_binary(reloaded.embedding_content_hash)
      end)
    end
  end

  describe "AC-37.4.3 / TC-37.4.4: a provider error writes NO vectors (batch fails as a unit)" do
    test "a mid-batch provider error leaves every memory un-embedded and errors for retry" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      seed_memories(tenant.id, 3)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, _texts ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      # Transient 5xx → the whole batch errors so Oban retries it as a unit.
      assert {:error, {:api_error, 500, :provider_error}} =
               BatchEmbeddingWorker.perform(job(tenant.id, "memory"))

      # NO partial writes: all three memories are still pending (embedding NULL).
      assert length(Memory.list_memories_pending_embedding(tenant.id, 10)) == 3
    end

    test "a permanent 4xx discards the batch (no retry, no writes)" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      seed_memories(tenant.id, 2)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, _texts ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:discard, {:embedding_permanent_error, {:api_error, 401, _}}} =
               BatchEmbeddingWorker.perform(job(tenant.id, "memory"))

      assert length(Memory.list_memories_pending_embedding(tenant.id, 10)) == 2
    end

    test "a keyless tenant (mandatory BYO) discards cleanly and writes nothing" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      seed_memories(tenant.id, 2)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, _texts ->
        {:error, :no_api_key}
      end)

      assert {:discard, {:no_embedding_key, "memory"}} =
               BatchEmbeddingWorker.perform(job(tenant.id, "memory"))

      assert length(Memory.list_memories_pending_embedding(tenant.id, 10)) == 2
    end
  end

  describe "AC-37.4.4: tenant isolation — a batch contains exactly one tenant's texts" do
    test "running the drainer for tenant A never embeds or reads tenant B's texts" do
      a = fixture(:tenant)
      b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(a.id)
      Knowledge.reset_circuit_breaker(b.id)

      seed_memories(a.id, 2)
      seed_memories(b.id, 2)

      test_pid = self()

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        send(test_pid, {:batch_texts, texts})
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      assert :ok = BatchEmbeddingWorker.perform(job(a.id, "memory"))

      assert_received {:batch_texts, texts}
      # A's texts ONLY — exactly A's 2 records, B's are never in the array
      # (AC-37.4.4 isolation). B has 2 pending too, so a leak would make this 4.
      assert length(texts) == 2
      assert Enum.all?(texts, &String.contains?(&1, "durable fact"))

      # B's memories are untouched (still pending); A's are all embedded.
      assert Memory.list_memories_pending_embedding(a.id, 10) == []
      assert length(Memory.list_memories_pending_embedding(b.id, 10)) == 2
    end
  end

  describe "empty pending set" do
    test "returns :ok without any provider call when nothing is pending" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 0, fn _tenant_id, _texts ->
        {:ok, []}
      end)

      assert :ok = BatchEmbeddingWorker.perform(job(tenant.id, "memory"))
    end
  end
end
