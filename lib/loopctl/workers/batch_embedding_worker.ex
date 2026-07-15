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

  ## Flow (one `perform/1` drains ONE fetch, then yields the slot)

  1. US-36.2 per-tenant fair-share gate on the contended `:embeddings` queue —
     yields the slot (loss-free `{:snooze, n}`) when this tenant is over its share.
  2. Fetch up to `batch_max` pending records for `(tenant, kind)`.
  3. Build the sliced embedding texts + content hashes.
  4. Sub-chunk the fetch by a per-request TOKEN budget (review MED #4) so a full
     count-batch of large texts can't 400 the provider (over the ~300k token/
     request cap) and get permanently discarded. Embed each sub-chunk in ONE array
     call via the GUARDED batch path `Knowledge.generate_embeddings/3` (per-tenant
     circuit breaker + ONE US-37.2 concurrency slot + provider-error telemetry
     recorded once — never bypass it).
  5. Map each vector back to its record BY the response index (done in the client)
     and store each via `Knowledge.update_embedding/4` / `Memory.update_memory_embedding/4`.
  6. If the fetch was full (`>= batch_max`) there may be more pending, so the job
     RELEASES its `:embeddings` slot with `{:snooze, n}` (review MED #2) instead of
     looping in-process. The snoozed job re-runs, re-passes the fair-share gate at
     step 1, and drains the next fetch — already-stored records are excluded, so it
     makes progress and terminates on a short (tail) fetch. Releasing the slot
     between fetches is what actually enforces fairness: a single per-tenant drainer
     always ranks 0 in the fair-share gate (it is unique per `(tenant, kind)`), so a
     between-fetch RE-GATE would be a no-op and would let one tenant's bulk backlog
     hold a slot for the whole drain (minutes-to-hours), starving other tenants'
     drainers waiting for one of the 5 `:embeddings` slots. Snoozing frees the slot
     so Oban's queue dispatcher round-robins the next tenant's drainer in.

  Only `batch_max` records are held in memory per perform. Because a snooze re-runs
  the SAME unique job (kept in a non-terminal state), a record written DURING a
  snooze gap is picked up by the very next fetch — the narrow residual staleness is
  a write racing the FINAL (tail) perform, backstopped by `PendingEmbeddingSweepWorker`.

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

  # review HIGH #1: scope uniqueness to NON-TERMINAL states only. Oban's default
  # `unique` states include `:completed` (and `:cancelled`/`:discarded`), so a
  # record written within `period` of a drainer that already FINISHED would be
  # deduped against that terminal job and NO fresh drainer inserted — stranding the
  # record (indefinitely for memories, which have no other re-embed path). By
  # restricting to in-flight states, a write after a drain completes always
  # re-enqueues a drainer; the periodic `PendingEmbeddingSweepWorker` is the
  # backstop for the narrow window where a write races an EXECUTING drainer's final
  # fetch (that job's uniqueness still coalesces, but the sweep re-enqueues later).
  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    unique: [
      keys: [:tenant_id, :kind],
      states: [:available, :scheduled, :executing, :retryable],
      period: 300
    ],
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

  @max_text_length 32_000
  @default_batch_max 100
  # Snooze (seconds) used to RELEASE the :embeddings slot between drain fetches
  # (review MED #2) so a lone per-tenant drainer can't hold a slot for its whole
  # backlog. Small by design — it is a fairness yield, not a backoff; the snoozed
  # job re-runs promptly and drains the next fetch. Live-tunable.
  @default_drain_continue_snooze_s 1
  # review MED #4: per-request token budget. An OpenAI-compatible embeddings
  # request 400s (a PERMANENT error → whole chunk discarded) when the array's
  # combined tokens exceed ~300k. A full count-batch of large articles (100 * ~8k
  # tokens) blows past that, so we ALSO sub-chunk a fetched batch by an estimated
  # token budget. Default 200k keeps ~33% headroom under the ~300k ceiling for
  # estimation error. A single text is already sliced to `@max_text_length` chars
  # (~8k tokens), so it can never alone exceed the budget.
  @default_batch_max_tokens 200_000

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id, "kind" => kind}})
      when kind in ["article", "memory"] do
    # US-36.2: yield the :embeddings slot when this tenant is at/above its fair
    # share (loss-free {:snooze, n}, no attempt consumed). `id` excludes THIS
    # already-executing job from its own count. Each perform drains only ONE fetch
    # and snoozes to release the slot if more remains (review MED #2), so this gate
    # is re-evaluated on every continuation — a large backlog can't monopolize a
    # slot for minutes.
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

  defp batch_max_tokens do
    max(SystemConfig.get_int("embedding_batch_max_tokens", @default_batch_max_tokens), 1)
  end

  defp drain_continue_snooze_s do
    max(
      SystemConfig.get_int("embedding_drain_continue_snooze_s", @default_drain_continue_snooze_s),
      1
    )
  end

  # Drain ONE fetch (<= batch_max) of the tenant's pending records. The fetch is
  # embedded via one-or-more provider array calls (token sub-chunking, review MED
  # #4). A full fetch snoozes to release the slot and continue on re-run (review MED
  # #2); a short (tail) fetch returns :ok. A non-:ok embed result
  # (error/discard/snooze) short-circuits.
  defp drain(tenant_id, kind, batch_max) do
    case pending(tenant_id, kind, batch_max) do
      [] -> :ok
      records -> embed_and_continue(tenant_id, kind, batch_max, records)
    end
  end

  defp embed_and_continue(tenant_id, kind, batch_max, records) do
    case embed_records(tenant_id, kind, records) do
      :ok -> maybe_continue_drain(length(records), batch_max)
      other -> other
    end
  end

  # Split a fetched batch into token-bounded sub-chunks (review MED #4) and embed
  # each as its own provider array call, storing between. A sub-chunk error halts
  # the reduce and returns the error/discard/snooze; sub-chunks stored earlier keep
  # their vectors and are excluded from the pending set on retry (AC-37.4.3).
  defp embed_records(tenant_id, kind, records) do
    records
    |> chunk_by_token_budget(batch_max_tokens())
    |> Enum.reduce_while(:ok, fn sub_chunk, _acc ->
      case embed_chunk(tenant_id, kind, sub_chunk) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  # Greedily pack records into sub-chunks whose combined estimated tokens stay
  # under `max_tokens`. Every sub-chunk holds at least one record (a lone
  # already-sliced text can never exceed the budget), so this always makes progress.
  defp chunk_by_token_budget(records, max_tokens) do
    {chunks, current, _tokens} =
      Enum.reduce(records, {[], [], 0}, fn record, {chunks, current, tokens} ->
        t = est_tokens(record.text)

        cond do
          current == [] -> {chunks, [record], t}
          tokens + t > max_tokens -> {[Enum.reverse(current) | chunks], [record], t}
          true -> {chunks, [record | current], tokens + t}
        end
      end)

    [Enum.reverse(current) | chunks] |> Enum.reverse()
  end

  # ~4 bytes/token heuristic (OpenAI-compatible). Deliberately a slight OVER-count
  # (`+ 1`) so the budget errs toward smaller, safe requests.
  defp est_tokens(text), do: div(byte_size(text), 4) + 1

  # A full fetch means there may be more pending — RELEASE the :embeddings slot with
  # `{:snooze, n}` (review MED #2) rather than looping in-process. The snoozed job
  # re-runs, re-passes the top fair-share gate, and drains the next fetch (already-
  # stored records excluded). Freeing the slot between fetches is what enforces
  # fairness: a lone per-tenant drainer always ranks 0, so a between-fetch RE-GATE
  # was a no-op that let one tenant hold a slot for its entire backlog. A short
  # fetch drained the tail → :ok.
  defp maybe_continue_drain(fetch_size, batch_max) when fetch_size >= batch_max do
    {:snooze, drain_continue_snooze_s()}
  end

  defp maybe_continue_drain(_fetch_size, _batch_max), do: :ok

  defp embed_chunk(tenant_id, kind, records) do
    texts = Enum.map(records, & &1.text)

    # No explicit :timeout — the guarded batch path derives its Task.yield budget
    # from the client's live-tunable receive-timeout/retry knobs (review MED #1).
    case Knowledge.generate_embeddings(tenant_id, texts) do
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
