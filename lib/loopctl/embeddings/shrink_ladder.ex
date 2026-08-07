defmodule Loopctl.Embeddings.ShrinkLadder do
  @moduledoc """
  Walks `Loopctl.Embeddings.TextBudget`'s byte ladder on a provider
  `:context_length_exceeded` rejection, for BOTH the single-text and the array
  embedding paths.

  #615 added the ladder to `ArticleEmbeddingWorker` and (via dissolve)
  `BatchArticleEmbeddingWorker`. Every OTHER embedding write path still mapped an
  input-too-long rejection onto `Llm.permanent_provider_error?/1`, which is `true`
  for any 4xx — so the job DISCARDED and the row stayed permanently un-embedded.
  That is the same shape as the outage #615 fixed, one call site over:

    * `ReembedWorker` — discards mid-run, so the tenant's re-embed never reaches
      `complete_reembed` and recall stays pinned at the old dimension forever.
    * `SystemCorpusEmbeddingWorker` — the canonical stays keyword-only for that
      tenant, with `system_corpus_meta/2` still reporting "semantic".
    * `MemoryEmbeddingWorker` and the synchronous promotion near-dup read in
      `Loopctl.Memory` — the memory is invisible to semantic recall, and the
      near-dup check that guards against duplicate promotions silently degrades.
    * `Knowledge.ProposalGate` — the novelty gate falls OPEN, so the over-long
      article skips dedup entirely and lands as the duplicate the nightly
      consolidation pass then has to catch.

  ## Single text: halve what was SENT

  `embed_one/3` re-truncates the bytes ACTUALLY SENT and re-sends, exactly as
  `ArticleEmbeddingWorker` does. Deriving the next rung from a nominal budget
  instead would let a budget larger than the text truncate nothing and buy a
  byte-identical rejection.

  ## An array: BISECT, then ladder the singleton

  A provider rejects the whole array and never says which member was over-long.
  Shrinking every text would truncate articles that were never over the limit;
  re-sending the array buys an identical rejection forever.

  So `embed_batch/3` splits the array in half and embeds each half independently,
  recursing until the rejection isolates to ONE text — which then walks the ladder.
  Only the offending text is truncated; its innocent neighbours are re-sent whole.
  This costs extra provider calls (~2·log2(n)), but ONLY on a batch that already
  failed, and only in place of a discard.

  `BatchArticleEmbeddingWorker` solves the same problem by DISSOLVING to
  per-article jobs. That is the better answer where a per-item worker exists at the
  same dimension and model; it does not here — `ReembedWorker` embeds at a PENDING
  dimension with a pinned model, and re-enqueueing through `ArticleEmbeddingWorker`
  would write the ACTIVE dimension instead.
  """

  require Logger

  alias Loopctl.Embeddings.TextBudget

  @type vector :: [float()]
  @type one_result :: {:ok, vector()} | {:error, term()}
  @type batch_result :: {:ok, [vector()]} | {:error, term()}

  @doc """
  Embed ONE text through `embed_fun`, shrinking on a context-length rejection.

  `embed_fun` receives the (possibly truncated) text and returns whatever the
  guarded embedding client returns. Every non-`:context_length_exceeded` result —
  success, egress refusal, circuit-open, throttle — is passed through untouched, so
  the caller's existing error handling is unchanged.

  On an exhausted ladder the ORIGINAL error is returned, so the caller discards it
  as the different defect it is (a much smaller model window, e.g. a self-hosted
  512-token embedder) rather than absorbing it in more halving.
  """
  @spec embed_one(String.t(), (String.t() -> one_result()), keyword()) :: one_result()
  def embed_one(text, embed_fun, opts \\ [])
      when is_binary(text) and is_function(embed_fun, 1) do
    case embed_fun.(text) do
      {:error, {:api_error, _status, :context_length_exceeded}} = error ->
        shrink_one(text, embed_fun, opts, error)

      result ->
        result
    end
  end

  defp shrink_one(text, embed_fun, opts, error) do
    sent = byte_size(text)

    case TextBudget.next_budget(sent) do
      :exhausted ->
        log_exhausted(opts, sent)
        error

      smaller ->
        log_shrink(opts, sent, smaller)
        embed_one(TextBudget.truncate(text, smaller), embed_fun, opts)
    end
  end

  @doc """
  Embed an ARRAY of texts through `embed_fun`, bisecting on a context-length
  rejection until the offender is isolated, then laddering it.

  `embed_fun` receives a list of texts and returns `{:ok, vectors}` or
  `{:error, reason}`. Vectors come back in the SAME ORDER as `texts` — the bisect
  concatenates left before right — so the caller can keep zipping them against its
  own entries.

  A short/misaligned `{:ok, vectors}` is normalized to
  `{:error, :embedding_batch_length_mismatch}`, matching what the call sites
  already did inline, so a contract violation cannot be zipped into misattributed
  vectors.
  """
  @spec embed_batch([String.t()], ([String.t()] -> batch_result()), keyword()) :: batch_result()
  def embed_batch(texts, embed_fun, opts \\ [])

  def embed_batch([], _embed_fun, _opts), do: {:ok, []}

  def embed_batch(texts, embed_fun, opts)
      when is_list(texts) and is_function(embed_fun, 1) do
    case embed_fun.(texts) do
      {:ok, vectors} when length(vectors) == length(texts) ->
        {:ok, vectors}

      {:ok, _mismatch} ->
        {:error, :embedding_batch_length_mismatch}

      {:error, {:api_error, _status, :context_length_exceeded}} = error ->
        shrink_batch(texts, embed_fun, opts, error)

      other ->
        other
    end
  end

  # Isolated to ONE text: this is the member the provider was rejecting, so ladder it.
  defp shrink_batch([text], embed_fun, opts, error) do
    sent = byte_size(text)

    case TextBudget.next_budget(sent) do
      :exhausted ->
        log_exhausted(opts, sent)
        error

      smaller ->
        log_shrink(opts, sent, smaller)
        embed_batch([TextBudget.truncate(text, smaller)], embed_fun, opts)
    end
  end

  # More than one member: the provider named none of them, so split and let each
  # half answer for itself. `div(length, 2)` is >= 1 here (length >= 2), so both
  # halves are strictly smaller and the recursion terminates.
  defp shrink_batch(texts, embed_fun, opts, _error) do
    {left, right} = Enum.split(texts, div(length(texts), 2))

    Logger.warning(
      "#{label(opts)}: batch of #{length(texts)} rejected as too long — the provider does " <>
        "not say which member, so bisecting into #{length(left)} + #{length(right)} to " <>
        "isolate it. Only the over-long text will be truncated."
    )

    with {:ok, left_vectors} <- embed_batch(left, embed_fun, opts),
         {:ok, right_vectors} <- embed_batch(right, embed_fun, opts) do
      {:ok, left_vectors ++ right_vectors}
    end
  end

  defp log_shrink(opts, sent, smaller) do
    Logger.warning(
      "#{label(opts)}: input exceeded the provider token limit at #{sent} bytes; retrying " <>
        "at #{smaller}. The embedding will cover a prefix of the text, not all of it."
    )
  end

  defp log_exhausted(opts, sent) do
    Logger.warning(
      "#{label(opts)}: input rejected as too long at #{sent} bytes, at or below the " <>
        "#{TextBudget.floor_bytes()}-byte floor — not a length problem (a smaller model " <>
        "window?); giving up on the ladder and surfacing the provider error."
    )
  end

  defp label(opts), do: Keyword.get(opts, :label, "ShrinkLadder")
end
