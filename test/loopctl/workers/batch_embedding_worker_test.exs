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
  alias Loopctl.ObanConfig
  alias Loopctl.Workers.BatchEmbeddingWorker

  defp job(tenant_id, kind, id \\ System.unique_integer([:positive])) do
    %Oban.Job{
      id: id,
      args: %{"tenant_id" => tenant_id, "kind" => kind}
    }
  end

  # review MED #2: each perform drains ONE fetch and returns {:snooze, n} to RELEASE
  # the :embeddings slot when the backlog exceeds `batch_max`, so a lone drainer
  # can't hold a slot for its whole backlog. In inline tests (no Oban re-dispatch) we
  # drive the continuation ourselves: re-run perform on a snooze until a terminal
  # result (:ok / {:error, _} / {:discard, _}). The record set shrinks each fetch, so
  # this terminates. Fair-share (top-gate) snoozes are exercised separately.
  defp drain_fully(job) do
    case BatchEmbeddingWorker.perform(job) do
      {:snooze, _n} -> drain_fully(job)
      other -> other
    end
  end

  # Simulate occupied executing :embeddings slots for a tenant without running a
  # job (a direct insert does not trigger the inline executor). Mirrors
  # fair_share_gate_test.exs.
  defp seed_executing(tenant_id, n) do
    for _ <- 1..n do
      %{"tenant_id" => tenant_id}
      |> Oban.Job.new(worker: "Loopctl.Workers.BatchEmbeddingWorker", queue: "embeddings")
      |> Ecto.Changeset.put_change(:state, "executing")
      |> AdminRepo.insert!()
    end
  end

  # Insert N un-embedded long-term memories directly (no remember/2 → no inline
  # enqueue), one query. `text_fun` builds each row's text from its index.
  defp seed_memories(tenant_id, n, text_fun \\ &"durable fact number #{&1}") do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          subject_id: "subj",
          text: text_fun.(i),
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
      # The drain spans 3 performs (each fetch snoozes to yield the slot — review
      # MED #2); drain_fully drives the continuations, so the CALL COUNT (3, not 250)
      # is what proves array batching regardless of how many performs it took.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 3, fn _tenant_id, texts ->
        assert length(texts) <= 100
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 1536) end)}
      end)

      assert :ok = drain_fully(job(tenant.id, "memory"))

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

  describe "review HIGH #1: uniqueness is scoped to NON-TERMINAL states" do
    test "resolved unique.states excludes :completed / :cancelled / :discarded" do
      # The stranding bug: Oban's DEFAULT unique states include :completed, so a
      # record written within `period` of a FINISHED drainer is deduped against
      # that terminal job and no fresh drainer is inserted. Guard the scoping fix.
      unique =
        BatchEmbeddingWorker.new(%{tenant_id: Ecto.UUID.generate(), kind: "memory"})
        |> Ecto.Changeset.get_field(:unique)

      assert :available in unique.states
      assert :scheduled in unique.states
      assert :executing in unique.states
      assert :retryable in unique.states

      refute :completed in unique.states
      refute :cancelled in unique.states
      refute :discarded in unique.states
    end

    test "two enqueues for the same (tenant, kind) coalesce; a different kind is distinct" do
      tenant = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, j1} =
                 BatchEmbeddingWorker.new(%{tenant_id: tenant.id, kind: "memory"})
                 |> Oban.insert()

        assert {:ok, j2} =
                 BatchEmbeddingWorker.new(%{tenant_id: tenant.id, kind: "memory"})
                 |> Oban.insert()

        # Same (tenant, kind) in a non-terminal state → deduped to the SAME job.
        assert j1.id == j2.id

        # A different kind is a distinct dedup key → its own job.
        assert {:ok, j3} =
                 BatchEmbeddingWorker.new(%{tenant_id: tenant.id, kind: "article"})
                 |> Oban.insert()

        refute j3.id == j1.id
      end)
    end
  end

  describe "review MED #4: a fetched batch is sub-chunked by a per-request TOKEN budget" do
    test "records well under the count cap still split into multiple array calls by tokens" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      # 30 records is far below the default count cap (batch_max=100), so a single
      # drain fetches all 30 at once. Each text is sliced to 32_000 chars
      # (~8k est tokens); 30 * 8k ≈ 240k tokens > the 200k default budget, so the
      # SINGLE fetch MUST split into >1 provider call — proving token sub-chunking,
      # not count chunking. Without it, this would be one ~240k-token call that a
      # real provider 400s (permanent) and discards.
      big = String.duplicate("x", 40_000)
      assert 30 = seed_memories(tenant.id, 30, fn i -> "#{i} #{big}" end)

      test_pid = self()
      budget = 200_000

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _tenant_id, texts ->
        est = Enum.reduce(texts, 0, fn t, acc -> acc + div(byte_size(t), 4) + 1 end)
        send(test_pid, {:chunk, length(texts), est})
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      assert :ok = BatchEmbeddingWorker.perform(job(tenant.id, "memory"))

      chunks = drain_chunk_messages([])

      # More than one call for 30 (< 100 count-cap) records ⇒ token-driven split.
      assert length(chunks) >= 2
      # Every array call stayed within the per-request token budget.
      assert Enum.all?(chunks, fn {_n, est} -> est <= budget end)
      # All 30 embedded — nothing stranded.
      assert Memory.list_memories_pending_embedding(tenant.id, 100) == []
    end
  end

  describe "review MED #6: cross-chunk partial progress (AC-37.4.3 atomicity across the drain loop)" do
    test "chunk 1+2 stored, chunk 3 errors → the first 200 keep vectors, the last 50 stay pending" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      assert 250 = seed_memories(tenant.id, 250)

      # 250 records, batch_max=100 → three drain fetches ACROSS three performs (each
      # full fetch snoozes to yield the slot — review MED #2; drain_fully drives the
      # continuations). Mox uses expectations in order: the first two fetches succeed
      # and STORE, the third errors — so the job returns {:error, _} for an Oban retry
      # while the already-stored 200 keep their vectors (excluded from the pending
      # set) and only the last 50 remain.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 2, fn _tenant_id, texts ->
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 1, fn _tenant_id, _texts ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      assert {:error, {:api_error, 500, :provider_error}} =
               drain_fully(job(tenant.id, "memory"))

      # Exactly the 50 un-stored records remain pending; the 200 stored are excluded.
      assert length(Memory.list_memories_pending_embedding(tenant.id, 500)) == 50
    end
  end

  describe "review MED #2: a full fetch YIELDS the :embeddings slot (snooze) instead of looping the whole backlog" do
    test "one perform drains ONE fetch then snoozes while more remains pending" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      # 150 > batch_max (100): the FIRST fetch is full, so the drainer must release
      # its slot ({:snooze, n}) rather than loop in-process and hold the slot for the
      # rest of the backlog (the head-of-line-blocking regression this fix removes).
      assert 150 = seed_memories(tenant.id, 150)

      # EXACTLY one array call in this single perform — the second fetch happens only
      # on the (snoozed) re-run.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 1, fn _tenant_id, texts ->
        assert length(texts) == 100
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      assert {:snooze, n} = BatchEmbeddingWorker.perform(job(tenant.id, "memory"))
      assert is_integer(n) and n > 0

      # Exactly the first 100 were embedded; 50 remain for the continuation — the
      # slot is freed between fetches so another tenant's drainer can run.
      assert length(Memory.list_memories_pending_embedding(tenant.id, 500)) == 50
    end

    test "a short (tail) fetch returns :ok without snoozing" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      # 40 < batch_max: a single short fetch drains the tail, so the perform returns
      # :ok directly (no continuation snooze).
      assert 40 = seed_memories(tenant.id, 40)

      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 1, fn _tenant_id, texts ->
        {:ok, Enum.map(texts, &det_vec/1)}
      end)

      assert :ok = BatchEmbeddingWorker.perform(job(tenant.id, "memory"))
      assert Memory.list_memories_pending_embedding(tenant.id, 500) == []
    end
  end

  describe "review MED #5: fair share gates the drain (same path re-checked between chunks)" do
    test "over-share yields the slot (snooze) before any provider call — nothing embedded" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      cap = ObanConfig.tenant_fair_share_cap(:embeddings)

      # Tenant already holds `cap` executing :embeddings slots (low ids). A drainer
      # with a HIGHER id is over its rank → the gate snoozes. This is the exact
      # `FairShare.gate/3` call re-run between drain chunks (review MED #5), so the
      # re-gate cannot let a large backlog monopolize a slot for minutes.
      seed_executing(tenant.id, cap)
      seed_memories(tenant.id, 3)

      # The gate short-circuits BEFORE any embedding call.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 0, fn _t, _texts -> {:ok, []} end)

      assert {:snooze, n} = BatchEmbeddingWorker.perform(job(tenant.id, "memory", 2_000_000_000))
      assert is_integer(n) and n > 0

      # Loss-free: the memories are untouched and still pending for a later drain.
      assert length(Memory.list_memories_pending_embedding(tenant.id, 10)) == 3
    end
  end

  # Collect the {:chunk, count, est_tokens} messages emitted by the token-budget stub.
  defp drain_chunk_messages(acc) do
    receive do
      {:chunk, n, est} -> drain_chunk_messages([{n, est} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
