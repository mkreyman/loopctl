defmodule Loopctl.Workers.BatchEmbeddingWorker do
  @moduledoc """
  US-37.4: per-tenant BATCH embedding worker. Drains a tenant's pending
  (un-embedded / content-stale) records in ARRAY batches of up to
  `embedding_batch_max` (~100), issuing `ceil(N / batch_max)` provider calls
  instead of N — the efficiency win that replaces the per-item fan-out of
  `ArticleEmbeddingWorker` / `MemoryEmbeddingWorker` for background embedding.

  ## Why a per-tenant batch worker (not per-item)

  The single-item workers embedded one record per job (one provider round-trip
  each). Under bulk ingest that is N round-trips for N records. This worker is
  enqueued ONCE per tenant + `kind` (`unique: [keys: [:tenant_id, :kind]]`), so
  many near-simultaneous writes coalesce into a single drainer that batches the
  provider calls. The interactive single-query path (`Knowledge.generate_embedding/3`
  used by search, novelty scoring, `Memory.recall/2`) is UNCHANGED — still
  single-text and latency-sensitive.

  ## Flow (one `perform/1`)

  1. US-36.2 per-tenant fair-share gate on the contended `:embeddings` queue —
     yields the slot (loss-free `{:snooze, n}`) when this tenant is over its share.
  2. Fetch up to `batch_max` pending records for `(tenant, kind)`.
  3. Build the sliced embedding texts + content hashes.
  4. Embed the whole chunk in ONE array call via the GUARDED batch path
     `Knowledge.generate_embeddings/3` (per-tenant circuit breaker + ONE US-37.2
     concurrency slot + provider-error telemetry recorded once — never bypass it).
  5. Map each vector back to its record BY the response index (done in the client)
     and store each via `Knowledge.update_embedding/4` / `Memory.update_memory_embedding/4`.
  6. If the chunk was full (`>= batch_max`), loop to drain the next chunk — so the
     whole backlog is embedded in one job, `ceil(N / batch_max)` calls total, with
     only `batch_max` records held in memory at a time. Stored records leave the
     pending set, so the loop terminates.

  ## Atomicity (AC-37.4.3)

  If the provider array call errors, NOTHING is written for that chunk — the job
  returns `{:error, ...}` and Oban retries the whole batch as a unit. Chunks
  already stored in earlier loop iterations have their embedding+hash set, so they
  are excluded from the pending set on retry and are never re-billed.

  ## BYO / permanent-error / rate-limit semantics (mirrors the single-item workers)

  - `{:error, :no_api_key}` (mandatory BYO) → `{:discard, {:no_embedding_key, kind}}`
    (clean skip, no crash, no operator-key fallback).
  - `{:error, :rate_limited_local}` (US-37.1 node-local admission) → `{:snooze, n}`
    (loss-free backpressure, no attempt consumed).
  - permanent 4xx (bad/revoked key — tenant-wide, so the whole batch fails
    identically) → `{:discard, {:embedding_permanent_error, sanitized}}`.
  - transient (5xx / network / timeout / circuit-open) → `{:error, sanitized}` for
    retry. The sanitized-away raw body is NEVER logged or persisted.

  ## Tenant isolation (AC-37.4.4)

  The pending readers filter by `tenant_id`, so a batch array contains exactly one
  tenant's texts (BYO key is per-tenant anyway).
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    unique: [keys: [:tenant_id, :kind], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Memory
  alias Loopctl.Oban.FairShare
  alias Loopctl.Provider.Admission
  alias Loopctl.SystemConfig
  alias Loopctl.Workers.ArticleLinkingWorker

  # Task.yield budget for the guarded batch path. Larger than the single-item
  # worker's 8s: the array call carries up to ~100 texts, and must stay strictly
  # above the client's batch receive_timeout (default 30s) so a valid response
  # returns before the guard kills the task.
  @batch_yield_ms 32_000
  @max_text_length 32_000
  @default_batch_max 100

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id, "kind" => kind}})
      when kind in ["article", "memory"] do
    # US-36.2: yield the :embeddings slot when this tenant is at/above its fair
    # share (loss-free {:snooze, n}, no attempt consumed). `id` excludes THIS
    # already-executing job from its own count.
    case FairShare.gate(tenant_id, :embeddings, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> drain(tenant_id, kind, batch_max())
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp batch_max do
    max(SystemConfig.get_int("embedding_batch_max", @default_batch_max), 1)
  end

  # Drain the tenant's pending records one chunk (<= batch_max) at a time. Each
  # chunk is exactly one provider array call, so N records => ceil(N/batch_max)
  # calls in this single perform. Stored records leave the pending set, so the
  # loop terminates; a non-:ok chunk result (error/discard/snooze) short-circuits.
  defp drain(tenant_id, kind, batch_max) do
    case pending(tenant_id, kind, batch_max) do
      [] -> :ok
      records -> embed_and_continue(tenant_id, kind, batch_max, records)
    end
  end

  defp embed_and_continue(tenant_id, kind, batch_max, records) do
    case embed_chunk(tenant_id, kind, records) do
      :ok -> maybe_continue_drain(tenant_id, kind, batch_max, length(records))
      other -> other
    end
  end

  # A full chunk means there may be more pending — loop. A short chunk drained the
  # tail. Stored records leave the pending set, so this terminates.
  defp maybe_continue_drain(tenant_id, kind, batch_max, chunk_size)
       when chunk_size >= batch_max,
       do: drain(tenant_id, kind, batch_max)

  defp maybe_continue_drain(_tenant_id, _kind, _batch_max, _chunk_size), do: :ok

  defp embed_chunk(tenant_id, kind, records) do
    texts = Enum.map(records, & &1.text)

    case Knowledge.generate_embeddings(tenant_id, texts, timeout: @batch_yield_ms) do
      {:ok, vectors} ->
        store_all(tenant_id, kind, records, vectors)

      {:error, :no_api_key} ->
        skip_no_embedding_key(tenant_id, kind, length(records))

      {:error, :rate_limited_local} ->
        # US-37.1 (AC-37.1.4): node-local admission rate-limit is loss-free
        # backpressure, NOT a failure — snooze (no attempt consumed).
        {:snooze, Admission.snooze_seconds()}

      {:error, reason} ->
        # The provider errored for the WHOLE array call, so NO vectors were written
        # (AC-37.4.3). The term that becomes an Oban discard/error reason is
        # SANITIZED — never a raw body. Provider-error telemetry was already recorded
        # once, upstream, in Knowledge.run_capped_embedding_batch_task/3.
        sanitized = ProviderError.sanitize(reason)

        if Llm.permanent_provider_error?(reason) do
          Logger.debug(
            "BatchEmbeddingWorker: tenant=#{tenant_id} kind=#{kind} permanent embedding " <>
              "error (#{ProviderError.log_tag(reason)}); discarding batch."
          )

          {:discard, {:embedding_permanent_error, sanitized}}
        else
          {:error, sanitized}
        end
    end
  end

  # Store every vector, mapped to its record by input order (the client already
  # reassembled vectors in input order from the response index). A store failure
  # halts and returns {:error, _} so Oban retries the whole batch; records stored
  # before the failure keep their embedding+hash and are excluded on retry.
  defp store_all(tenant_id, kind, records, vectors) do
    records
    |> Enum.zip(vectors)
    |> Enum.reduce_while(:ok, fn {record, vector}, _acc ->
      case store_one(tenant_id, kind, record, vector) do
        :ok -> {:cont, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  defp store_one(tenant_id, "article", %{id: article_id} = record, vector) do
    hash = content_hash(record.text)

    case Knowledge.update_embedding(tenant_id, article_id, vector, hash) do
      {:ok, _article} ->
        enqueue_linking(article_id, tenant_id)
        :ok

      # Article deleted between fetch and store — nothing to do.
      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_one(tenant_id, "memory", %{id: memory_id} = record, vector) do
    hash = Memory.Memory.embedding_content_hash(record.text)

    case Memory.update_memory_embedding(tenant_id, memory_id, vector, hash) do
      {:ok, _memory} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending(tenant_id, "article", limit) do
    tenant_id
    |> Knowledge.list_articles_pending_embedding(limit)
    |> Enum.map(fn %{id: id, title: title, body: body} ->
      %{id: id, text: build_article_text(title, body)}
    end)
  end

  defp pending(tenant_id, "memory", limit) do
    tenant_id
    |> Memory.list_memories_pending_embedding(limit)
    |> Enum.map(fn %{id: id, text: text} ->
      %{id: id, text: Memory.Memory.embedding_input(text)}
    end)
  end

  defp build_article_text(title, body) do
    "#{title}\n\n#{body}"
    |> String.slice(0, @max_text_length)
  end

  # Article content hash: sha256 over the sliced embedding text (matches the
  # per-item ArticleEmbeddingWorker so the two never disagree on staleness).
  defp content_hash(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  # Mandatory BYO: the tenant has no embedding key, so no provider call was made
  # and NOTHING was billed. Emit the skipped_no_key signal for the whole chunk and
  # record a single blocked event, then cleanly discard (no crash, no retry).
  defp skip_no_embedding_key(tenant_id, kind, count) do
    :telemetry.execute(
      [:loopctl, :embedding, :skipped_no_key],
      %{count: count},
      %{tenant_id: tenant_id, source: kind}
    )

    Llm.record_blocked(tenant_id, :embedding)

    Logger.debug(
      "BatchEmbeddingWorker: tenant=#{tenant_id} kind=#{kind} skipped #{count} record(s) — " <>
        "no embedding API key configured (mandatory BYO)."
    )

    {:discard, {:no_embedding_key, kind}}
  end

  defp enqueue_linking(article_id, tenant_id) do
    ArticleLinkingWorker.new(%{article_id: article_id, tenant_id: tenant_id})
    |> Oban.insert()
  end
end
