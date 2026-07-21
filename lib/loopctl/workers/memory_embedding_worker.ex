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

  alias Loopctl.Custody
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope

  import Loopctl.Egress, only: [is_egress_refusal: 1]
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.Dimensions
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
            generate_and_store(memory, tenant_id, memory_id, memory.project_id)
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp generate_and_store(memory, tenant_id, memory_id, project_id) do
    text = build_embedding_text(memory)
    content_hash = content_hash(text)

    if already_embedded?(tenant_id, memory, content_hash) do
      # Idempotent no-op: this exact content is already embedded. Never re-call the
      # paid provider.
      :ok
    else
      generate(tenant_id, memory_id, text, content_hash, project_id)
    end
  end

  defp generate(tenant_id, memory_id, text, content_hash, project_id) do
    # US-41.7 (AC-41.7.1/.2): the memory embedding is its own content-touching
    # operation and gets its own custody posture entry.
    #
    # The scope carries the MEMORY'S OWN `project_id`, read off the row (the job
    # args carry only memory_id/tenant_id). Memories DO carry a project_id
    # (`Loopctl.Memory.Memory`), and both create paths assign their posture with
    # `EgressScope.new(tenant_id, project_id)` — while `Egress.effective_local_only?/1`
    # matches ONLY the tenant-wide marking when project_id is nil. A tenant-only
    # scope here would therefore make a project-scoped `local_only` memory's create
    # claimable while its embed silently allocated nothing, producing a COMPLETE,
    # zero-egress claim for a row whose body was POSTed to the provider. It would
    # also key `Policy.classify/3` on the wrong `Scope.key/1`, so a project-scoped
    # trusted-endpoint declaration would not be applied and the RECORDED verdict
    # could differ from the one the guard enforced (the AC-41.4.9 drift).
    #
    # Recorded BEFORE the call so a provider failure that happens AFTER the body
    # left the process still leaves a recorded operation naming the endpoint, and
    # never a contiguous sequence that omits it.
    result = embed_with_custody(tenant_id, memory_id, text, project_id)

    case result do
      {:ok, embedding} ->
        store(tenant_id, memory_id, embedding, content_hash)

      {:error, :no_api_key} ->
        skip_no_embedding_key(tenant_id, memory_id)

      {:error, refusal} when is_egress_refusal(refusal) ->
        # US-41.4 (AC-41.4.3): the ONE mapping from an egress refusal to an Oban
        # outcome lives in `Loopctl.Egress.oban_result/1`: `:egress_blocked` CANCELS
        # (a permanent configuration state; retrying burns max_attempts and no data
        # was sent), while `:pin_stale` / `:egress_unavailable` SNOOZE (an IP change
        # or a DB hiccup is recoverable, and cancelling would silently strand the
        # item). The cancel reason NAMES the scope and the offending endpoint
        # (AC-41.4.6).
        Egress.oban_result(refusal)

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

  defp embed_with_custody(tenant_id, memory_id, text, project_id) do
    scope = Scope.new(tenant_id, project_id)
    recorded = Custody.record(scope, "memory", memory_id, :embed)

    result =
      Knowledge.generate_embedding(tenant_id, text, timeout: @worker_yield_ms, scope: scope)

    Custody.record_outcome(recorded, custody_outcome(result))
    result
  end

  defp custody_outcome({:ok, _}), do: :succeeded
  defp custody_outcome(_other), do: :failed

  defp store(tenant_id, memory_id, embedding, content_hash) do
    # Pre-write dimension check (review): an off-dimension model otherwise surfaced as a
    # changeset error, `perform` returned `{:error, _}`, and Oban re-billed the provider
    # on each of five attempts. Catch it before the write and DISCARD legibly. The pin
    # `resolve_write_dimension/1` sets is cached + idempotent, so resolving here and
    # again inside `update_memory_embedding/4` is a no-op second read.
    case Dimensions.check_batch_length([embedding], Embeddings.resolve_write_dimension(tenant_id)) do
      :ok -> do_store(tenant_id, memory_id, embedding, content_hash)
      {:error, {:dimension_mismatch, expected, actual}} -> discard_mismatch(expected, actual)
    end
  end

  defp do_store(tenant_id, memory_id, embedding, content_hash) do
    case Memory.update_memory_embedding(tenant_id, memory_id, embedding, content_hash) do
      {:ok, _memory} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_mismatch(expected, actual) do
    Logger.debug(
      "MemoryEmbeddingWorker: model returned #{inspect(actual)}-dimension vector but the tenant " <>
        "is recorded at #{expected}; discarding rather than re-billing."
    )

    {:discard, {:dimension_mismatch, expected, actual}}
  end

  # Snooze interval (seconds) for the OPEN-breaker path: ~the remaining cooldown so
  # the job wakes right as the breaker closes. Floored at `Admission.snooze_seconds/0`
  # (always >= 1) so a just-expired/raced window still yields a positive snooze — a
  # short re-snooze is loss-free (no attempt consumed), never a `{:snooze, 0}` loop.
  defp circuit_open_snooze_seconds(tenant_id) do
    max(Knowledge.circuit_breaker_cooldown_remaining(tenant_id), Admission.snooze_seconds())
  end

  # IDEMPOTENCY, at the ACTIVE dimension (review). The legacy `memories.embedding` /
  # `memories.embedding_content_hash` pair is NEVER written for a non-1536 dimension
  # (`Memory.update_memory_embedding/4` skips that step), so for exactly the 768/1024
  # tenants this epic serves this guard was permanently `false` and every enqueue
  # re-billed the paid provider. Behind the cutover flag it reads the hash the side
  # table has been recording all along.
  defp already_embedded?(tenant_id, memory, content_hash) do
    # WRITE-dimension gated (`use_side_table_hash?/1`), not read-flag gated (review):
    # a non-1536 tenant has no legacy hash, so the read-flag gate re-billed the provider
    # on every enqueue until cutover.
    if Embeddings.use_side_table_hash?(tenant_id) do
      Embeddings.memory_embedded_hash(
        tenant_id,
        memory.id,
        Embeddings.active_dimension(tenant_id)
      ) == content_hash
    else
      legacy_already_embedded?(memory, content_hash)
    end
  end

  defp legacy_already_embedded?(
         %{embedding: embedding, embedding_content_hash: hash},
         content_hash
       )
       when not is_nil(embedding) and is_binary(hash),
       do: hash == content_hash

  defp legacy_already_embedded?(_memory, _content_hash), do: false

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
