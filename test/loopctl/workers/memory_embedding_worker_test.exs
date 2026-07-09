defmodule Loopctl.Workers.MemoryEmbeddingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Workers.MemoryEmbeddingWorker

  defp job(memory_id, tenant_id) do
    %Oban.Job{args: %{"memory_id" => memory_id, "tenant_id" => tenant_id}}
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
  end
end
