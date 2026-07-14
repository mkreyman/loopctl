defmodule Loopctl.Workers.MemoryEmbeddingWorker do
  @moduledoc """
  Oban worker that generates and stores the vector embedding for a long-term
  agent memory (`Loopctl.Memory.Memory`), Epic 28 / US-28.2.

  Runs in the `:embeddings` queue. Enqueued by `Loopctl.Memory.remember/2` when a
  long-term memory is written (the row's `embedding` starts NULL). Mirrors
  `Loopctl.Workers.ArticleEmbeddingWorker` — same guarded embed path, content-hash
  idempotency, and BYO-key / permanent-error discard semantics.

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
     {:embedding_permanent_error, _}}`. Transient errors (5xx / network / timeout /
     circuit-open) return `{:error, reason}` for retry.

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

  @worker_yield_ms 8_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"memory_id" => memory_id, "tenant_id" => tenant_id}}) do
    case Memory.get_memory_for_embedding(tenant_id, memory_id) do
      {:error, :not_found} ->
        # Memory deleted -- no-op.
        :ok

      {:ok, memory} ->
        generate_and_store(memory, tenant_id, memory_id)
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

      {:error, reason} ->
        sanitized = ProviderError.sanitize(reason)
        record_provider_error(reason)

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

  # US-34.3 (AC-34.3.3): a genuine provider failure — never the circuit breaker's
  # own `:circuit_open` skip (a DERIVED consequence of prior failures already
  # counted when they happened, not a fresh one; counting it too would inflate the
  # rate every retry while the breaker stays open on a single underlying incident).
  defp record_provider_error(:circuit_open), do: :ok

  defp record_provider_error(reason) do
    class = if Llm.permanent_provider_error?(reason), do: :permanent, else: :transient
    Llm.record_provider_error("embedding", class)
  end

  defp store(tenant_id, memory_id, embedding, content_hash) do
    case Memory.update_memory_embedding(tenant_id, memory_id, embedding, content_hash) do
      {:ok, _memory} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
