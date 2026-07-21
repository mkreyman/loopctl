defmodule Loopctl.Workers.MemoryEmbeddingWorker do
  @moduledoc """
  Oban worker that generates and stores the vector embedding for a long-term
  agent memory (`Loopctl.Memory.Memory`), Epic 28 / US-28.2.

  Runs in the `:embeddings` queue. Enqueued by `Loopctl.Memory.remember/2` when a
  long-term memory is written (the row's `embedding` starts NULL). Mirrors
  `Loopctl.Workers.ArticleEmbeddingWorker` — same guarded embed path, content-hash
  idempotency, BYO-key / permanent-error discard semantics, AND the US-36.2 per-tenant
  fair-share gate at the top of `perform/1`. The gate is load-bearing here, not
  cosmetic: `:embeddings` is shared by TWO tenant-scoped per-item fan-out producers
  (this worker and `ArticleEmbeddingWorker`), and the gate counts executing slots by
  `(queue, state, tenant)` regardless of worker — so an ungated memory-embed burst
  would monopolize the queue against BOTH producers. Both must gate for fairness to
  hold (see `Loopctl.Oban.FairShare`).

  ## Flow

  1. Fetch the memory (with its `embedding` + content-hash) by `memory_id` + `tenant_id`.
  2. If the memory was deleted, return `:ok` (no-op).
  3. Build the embedding text: the memory `text`, SLICED to #{32_000} chars.

     NB: `Loopctl.Memory.Memory` caps `text` at 100KB (~25k tokens) — WELL beyond
     the embedder's ~8191-token window — so the slice here is load-bearing, not
     cosmetic. Mirrors `ArticleEmbeddingWorker`'s `@max_text_length`.
  4. IDEMPOTENCY: if the memory already carries an embedding whose stored
     content-hash matches the current text, skip the paid provider call entirely
     (`:ok`). An Oban retry after a post-embed failure never re-bills the tenant.
  5. Otherwise embed via the GUARDED `Loopctl.Knowledge.generate_embedding/3`
     (per-tenant circuit breaker + timeout) and store via
     `Loopctl.Memory.update_memory_embedding/4`.
  6. On `{:error, :no_api_key}` (mandatory BYO), `{:discard, {:no_embedding_key, _}}` —
     a clean skip: no crash, no retry, no operator-key fallback. The memory stays
     stored; it is simply not vector-recallable until the tenant configures a key.
  7. On a PERMANENT provider error (a 4xx other than 408/429), `{:discard,
     {:embedding_permanent_error, _}}`. Transient errors (5xx / network / timeout)
     return `{:error, reason}` for retry.
  8. On `{:error, :circuit_open}` (the tenant breaker is OPEN) the worker
     `{:snooze, remaining_cooldown}`s (US-37.3, AC-37.3.5) — a loss-free reschedule
     consuming NO attempt. NOT the `{:error, reason}` retry path: a honored
     Retry-After can hold the breaker open up to 300s (beyond the 4-attempt window),
     so `{:error, ...}` would discard the job and leave the memory permanently
     un-embedded (no embedding backfill).

  ## Uniqueness

  Unique per `memory_id` within a 300-second window; a new job for the same memory
  while one is pending replaces the existing job.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    unique: [keys: [:memory_id], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Memory
  alias Loopctl.Oban.FairShare
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter

  @worker_yield_ms 8_000

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"memory_id" => memory_id, "tenant_id" => tenant_id}}) do
    # US-36.2: per-tenant fair-share gate. `:embeddings` is a CONTENDED queue with TWO
    # tenant-scoped per-item fan-out producers — this worker (one job per long-term
    # memory, Memory.remember/2) AND ArticleEmbeddingWorker. Gating only the article
    # worker would leave this producer free to monopolize all executing slots with one
    # tenant's memory-embed burst (a bulk `memory_remember` or a MemoryPromotionSweep
    # promoting many session memories), starving other tenants — the exact
    # monopolization the story exists to stop. Yield the slot (loss-free {:snooze, n},
    # no attempt consumed) when this tenant already holds at/above its fair share.
    # `id` excludes THIS (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :embeddings, id) do
      {:snooze, _n} = snooze ->
        snooze

      :ok ->
        case Memory.get_memory_for_embedding(tenant_id, memory_id) do
          {:error, :not_found} ->
            # Memory deleted -- no-op.
            :ok

          {:ok, memory} ->
            generate_and_store(memory, tenant_id, memory_id)
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp generate_and_store(memory, tenant_id, memory_id) do
    text = build_embedding_text(memory)
    content_hash = content_hash(text)

    if already_embedded?(memory, content_hash) do
      # Idempotent no-op: this exact content is already embedded. Never re-call the
      # paid provider.
      :ok
    else
      generate(tenant_id, memory_id, text, content_hash)
    end
  end

  defp generate(tenant_id, memory_id, text, content_hash) do
    case Knowledge.generate_embedding(tenant_id, text, timeout: @worker_yield_ms) do
      {:ok, embedding} ->
        store(tenant_id, memory_id, embedding, content_hash)

      {:error, :no_api_key} ->
        skip_no_embedding_key(tenant_id, memory_id)

      {:error, egress} when egress in [:egress_blocked, :pin_stale] ->
        # US-41.4 (AC-41.4.3): a fail-CLOSED egress refusal is a PERMANENT
        # configuration state, not a transient failure. CANCEL — never {:error, _}
        # (Oban retries it, burning max_attempts with backoff on every item and
        # repopulating the queue on every subsequent write) and never {:snooze, _}
        # (an indefinite re-check loop against a config that will not change on its
        # own). No data was sent. Mirrors the terminal treatment US-41.5 requires
        # for blocked webhook deliveries.
        {:cancel, egress}

      {:error, :rate_limited_local} ->
        # US-37.1 (AC-37.1.4): a node-local provider admission rate-limit is
        # loss-free backpressure, NOT a failure. Snooze (no attempt consumed, never
        # a discard) so the embed retries once local demand subsides.
        {:snooze, Admission.snooze_seconds()}

      {:error, :circuit_open} ->
        # US-37.3 (AC-37.3.5): the tenant's embedding breaker is OPEN. Snooze
        # loss-free for ~the remaining open window (no Oban attempt consumed) rather
        # than {:error, ...}: with 429/408 now counting toward the breaker and a
        # honored Retry-After raising the open cooldown up to 300s (able to exceed a
        # job's 4-attempt window), {:error, ...} would burn every attempt and DISCARD
        # the job, leaving the memory permanently un-embedded (no embedding backfill).
        {:snooze, circuit_open_snooze_seconds(tenant_id)}

      {:error, {:api_error, _status, :provider_error, retry_after}}
      when is_integer(retry_after) ->
        # US-37.3 (AC-37.3.3): provider throttle (429/503) with a Retry-After —
        # snooze loss-free for ~that interval (no attempt consumed) instead of the
        # blind `attempt^4` backoff. Already clamped to the SystemConfig max at parse;
        # `RetryAfter.snooze_seconds/1` floors it POSITIVE so a `Retry-After: 0` can't
        # produce a `{:snooze, 0}` hot-reschedule.
        {:snooze, RetryAfter.snooze_seconds(retry_after)}

      {:error, reason} ->
        # US-34.3 (review MED #1): the `[:loopctl, :llm, :provider_error]` telemetry
        # signal is now recorded ONCE, upstream, in
        # `Loopctl.Knowledge.run_embedding_task/3` — the single choke point shared by
        # this worker AND every query-time embedding caller. Do NOT re-record here.
        sanitized = ProviderError.sanitize(reason)

        if Llm.permanent_provider_error?(reason) do
          Logger.debug(
            "MemoryEmbeddingWorker: tenant=#{tenant_id} memory=#{memory_id} permanent " <>
              "embedding error (#{ProviderError.log_tag(reason)}); discarding."
          )

          {:discard, {:embedding_permanent_error, sanitized}}
        else
          {:error, sanitized}
        end
    end
  end

  defp store(tenant_id, memory_id, embedding, content_hash) do
    case Memory.update_memory_embedding(tenant_id, memory_id, embedding, content_hash) do
      {:ok, _memory} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Snooze interval (seconds) for the OPEN-breaker path: ~the remaining cooldown so
  # the job wakes right as the breaker closes. Floored at `Admission.snooze_seconds/0`
  # (always >= 1) so a just-expired/raced window still yields a positive snooze — a
  # short re-snooze is loss-free (no attempt consumed), never a `{:snooze, 0}` loop.
  defp circuit_open_snooze_seconds(tenant_id) do
    max(Knowledge.circuit_breaker_cooldown_remaining(tenant_id), Admission.snooze_seconds())
  end

  defp already_embedded?(%{embedding: embedding, embedding_content_hash: hash}, content_hash)
       when not is_nil(embedding) and is_binary(hash),
       do: hash == content_hash

  defp already_embedded?(_memory, _content_hash), do: false

  defp content_hash(text) do
    # Delegates to the schema's single source of truth so the async worker hash and
    # the synchronous US-29.2 promotion write-time hash never drift. `text` here is
    # already `build_embedding_text/1` (the sliced input); `embedding_content_hash/1`
    # re-slices idempotently, so the hash is identical either way.
    Memory.Memory.embedding_content_hash(text)
  end

  defp skip_no_embedding_key(tenant_id, memory_id) do
    :telemetry.execute(
      [:loopctl, :embedding, :skipped_no_key],
      %{count: 1},
      # `source: "memory"` is the ONE bounded metadata tag US-34.4 (AC-34.4.4) adds at
      # this emit site — mirrors `ArticleEmbeddingWorker`'s addition so the
      # `loopctl.embedding.skipped_no_key.count` counter can distinguish article vs
      # memory skips without tagging the unbounded `memory_id`.
      %{tenant_id: tenant_id, memory_id: memory_id, source: "memory"}
    )

    Llm.record_blocked(tenant_id, :embedding)

    Logger.debug(
      "MemoryEmbeddingWorker: tenant=#{tenant_id} memory=#{memory_id} skipped — no " <>
        "embedding API key configured (mandatory BYO)."
    )

    {:discard, {:no_embedding_key, memory_id}}
  end

  defp build_embedding_text(memory) do
    Memory.Memory.embedding_input(memory.text)
  end
end
