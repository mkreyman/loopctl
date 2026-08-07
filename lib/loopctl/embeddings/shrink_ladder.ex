defmodule Loopctl.Embeddings.ShrinkLadder do
  @moduledoc """
  Walks `Loopctl.Embeddings.TextBudget`'s byte ladder on a provider
  `:context_length_exceeded` rejection, for BOTH the single-text and the array
  embedding paths.

  #615 added the ladder to the two article workers. Every OTHER embedding write path —
  `ReembedWorker`, `SystemCorpusEmbeddingWorker`, `MemoryEmbeddingWorker`,
  `Loopctl.Memory`'s promotion near-dup read, `Knowledge.ProposalGate` — still mapped an
  input-too-long rejection onto `Llm.permanent_provider_error?/1`, which is `true` for
  any 4xx, so the job DISCARDED and the row stayed permanently un-embedded.

  ## Single text: halve what was SENT

  `embed_one/3` re-truncates the bytes ACTUALLY SENT and re-sends, exactly as
  `ArticleEmbeddingWorker` does — deriving the next rung from a nominal budget would let
  a budget larger than the text truncate nothing and buy a byte-identical rejection.

  A shrunk result comes back as `{:ok, vector, :truncated}`, never as a bare
  `{:ok, vector}`. The vector covers a PREFIX, so it is NOT comparable with corpus
  vectors built from whole texts — `ProposalGate` may not call a proposal a duplicate
  on one, and `Memory` may not supersede a prior memory on one. A truncation the
  caller cannot see is a truncation it silently judges against. Refusing to JUDGE on one is
  only half of it: a prefix STORED unmarked is indistinguishable from a whole-text vector,
  and the next comparison runs the forbidden compare from the other side — this time
  retiring the longer text. No side table has a column for the fact, so the marker rides
  `embedding_content_hash` (`truncated_hash/1`).

  ## An array: BISECT, then ladder the singleton

  A provider rejects the whole array and never says which member was over-long.
  Shrinking every text would truncate articles that were never over the limit;
  re-sending the array buys an identical rejection forever. So `embed_batch/3` splits
  the array in half and embeds each half independently, recursing until the rejection
  isolates to ONE text — which then walks the ladder. Only the offender is truncated.
  (`BatchArticleEmbeddingWorker` DISSOLVES to per-article jobs instead, which is the
  better answer only where such a worker shares this one's dimension and model.)

  That costs ~2·log2(n) extra calls only when exactly ONE member is over-long; with k
  offenders it is ~2k·log2(n/k), degenerating towards 2n-1 when most of the batch
  overflows — the measured #615 corpus, not a hypothetical. A batch is therefore
  bounded twice: the caller pre-splits with `chunk_by_bytes/3` (an AGGREGATE rejection
  must never be answered by bisecting — every half fails too, so the batch pays the
  whole tree on every run instead of once), and `:max_calls` bounds what one
  already-failing batch may spend.
  """

  require Logger

  alias Loopctl.Embeddings.TextBudget

  # What ONE `embed_batch/3` may spend: `max(@min_max_calls, @calls_per_text * n)`. A budget
  # below the bisect's own worst case (~5n: n-1 internal nodes, plus per leaf its own call
  # and at most 3 rungs) abandons work the bisect could have finished, and the callers read
  # the surfaced 4xx through `permanent_provider_error?/1` — the job DISCARDS and the rows
  # stay un-embedded, the outage this module exists to end. So it guards against runaway
  # recursion, never caps a legitimate batch; callers bound COST via `chunk_by_bytes/3`.
  @min_max_calls 64
  @calls_per_text 6

  # See the moduledoc: no side table has a column for "this vector is a prefix".
  @truncated_hash_prefix "t:"

  @type vector :: [float()]
  @type one_result :: {:ok, vector()} | {:ok, vector(), :truncated} | {:error, term()}
  @type batch_result ::
          {:ok, [vector()]} | {:ok, [vector()], [non_neg_integer()]} | {:error, term()}

  @doc """
  Embed ONE text through `embed_fun`, shrinking on a context-length rejection.

  `embed_fun` receives the (possibly truncated) text and returns whatever the
  guarded embedding client returns. Every non-`:context_length_exceeded` result —
  success, egress refusal, circuit-open, throttle — is passed through untouched, so
  the caller's existing error handling is unchanged.

  A result the ladder had to shrink is `{:ok, vector, :truncated}`: the vector covers
  a prefix, and a caller that COMPARES it against whole-text vectors must not treat it
  as authoritative (see the moduledoc).

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

  # `:max_rungs` (default unbounded) caps how many times ONE text may be halved. A
  # SYNCHRONOUS caller pays each rung in request latency and in an embedding admission
  # slot that interactive search shares, so `ProposalGate` spends one and then accepts
  # its own fail-open — the background worker walks the full ladder for that row anyway.
  defp shrink_one(text, embed_fun, opts, error) do
    sent = byte_size(text)
    rungs = Keyword.get(opts, :max_rungs, :infinity)

    case TextBudget.next_budget(sent) do
      :exhausted ->
        log_exhausted(opts, sent)
        error

      _smaller when rungs == 0 ->
        Logger.warning(
          "#{label(opts)}: still too long at #{sent} bytes with the rung budget spent; " <>
            "surfacing the provider error rather than spending another round trip."
        )

        error

      smaller ->
        log_shrink(opts, sent, smaller)

        text
        |> TextBudget.truncate(smaller)
        |> embed_one(embed_fun, spend_rung(opts, rungs))
        |> mark_truncated()
    end
  end

  defp spend_rung(opts, :infinity), do: opts
  defp spend_rung(opts, rungs), do: Keyword.put(opts, :max_rungs, rungs - 1)

  # A vector produced from a shrunk text is tagged ONCE, at the rung that shrank it; a
  # deeper rung has already tagged its own, so the pass-through clause keeps it.
  defp mark_truncated({:ok, vector}), do: {:ok, vector, :truncated}
  defp mark_truncated(other), do: other

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

  A batch the ladder had to shrink comes back as `{:ok, vectors, truncated_indexes}` — the
  SAME contract `embed_one/3` carries, and for the same reason: a storing caller must mark
  those rows or the corpus fills with prefixes the comparing side is told cannot exist.
  `:max_calls` bounds the provider calls one batch may spend across the whole bisect
  (default `max(#{@min_max_calls}, #{@calls_per_text} * length(texts))`).
  """
  @spec embed_batch([String.t()], ([String.t()] -> batch_result()), keyword()) :: batch_result()
  def embed_batch(texts, embed_fun, opts \\ [])

  def embed_batch([], _embed_fun, _opts), do: {:ok, []}

  def embed_batch(texts, embed_fun, opts)
      when is_list(texts) and is_function(embed_fun, 1) do
    budget = Keyword.get(opts, :max_calls, max(@min_max_calls, @calls_per_text * length(texts)))
    # Back into `opts` so the give-up log names the budget ACTUALLY in force.
    opts = Keyword.put(opts, :max_calls, budget)
    {result, _left} = run_batch(texts, embed_fun, opts, budget, 0)

    case result do
      {:ok, vectors, []} -> {:ok, vectors}
      {:ok, vectors, truncated} -> {:ok, vectors, Enum.sort(truncated)}
      error -> error
    end
  end

  # Every result carries the REMAINING call budget, so the two halves of a bisect share one:
  # a per-branch budget would multiply with the depth and bound nothing. `offset` is the
  # index of `texts` in the ORIGINAL array, i.e. the index the caller zips its entries at.
  defp run_batch(texts, embed_fun, opts, budget, offset) do
    case embed_fun.(texts) do
      {:ok, v} when length(v) == length(texts) ->
        {{:ok, v, []}, budget - 1}

      {:ok, _mismatch} ->
        {{:error, :embedding_batch_length_mismatch}, budget - 1}

      {:error, {:api_error, _s, :context_length_exceeded}} = e ->
        shrink(texts, embed_fun, opts, e, budget - 1, offset)

      other ->
        {other, budget - 1}
    end
  end

  defp shrink(texts, _embed_fun, opts, error, budget, _offset) when budget <= 0 do
    Logger.warning(
      "#{label(opts)}: giving up on a batch of #{length(texts)} after " <>
        "#{Keyword.fetch!(opts, :max_calls)} provider calls — most of it is over-long, " <>
        "which no bisect can fix; surfacing the provider error. Split by bytes " <>
        "(`chunk_by_bytes/3`) before sending."
    )

    {error, 0}
  end

  # Isolated to ONE text: this is the member the provider was rejecting, so ladder it.
  defp shrink([text], embed_fun, opts, error, budget, offset) do
    sent = byte_size(text)

    case TextBudget.next_budget(sent) do
      :exhausted ->
        log_exhausted(opts, sent)
        {error, budget}

      smaller ->
        log_shrink(opts, sent, smaller)

        {result, left} =
          run_batch([TextBudget.truncate(text, smaller)], embed_fun, opts, budget, offset)

        {mark_index(result, offset), left}
    end
  end

  # More than one member: the provider named none of them, so split and let each
  # half answer for itself. `div(length, 2)` is >= 1 here (length >= 2), so both
  # halves are strictly smaller and the recursion terminates. A `with` else-less
  # fallthrough returns the failing `{result, budget}` pair unchanged.
  defp shrink(texts, embed_fun, opts, _error, budget, offset) do
    {left, right} = Enum.split(texts, div(length(texts), 2))

    Logger.warning(
      "#{label(opts)}: batch of #{length(texts)} rejected as too long — the provider does " <>
        "not say which member, so bisecting into #{length(left)} + #{length(right)} to " <>
        "isolate it. Only the over-long text will be truncated."
    )

    with {{:ok, lv, lt}, left_budget} <- run_batch(left, embed_fun, opts, budget, offset),
         {{:ok, rv, rt}, spent} <-
           run_batch(right, embed_fun, opts, left_budget, offset + length(left)) do
      {{:ok, lv ++ rv, lt ++ rt}, spent}
    end
  end

  # Tagged ONCE per member: a deeper rung already tagged the same index, hence the uniq.
  defp mark_index({:ok, v, truncated}, offset), do: {:ok, v, Enum.uniq([offset | truncated])}
  defp mark_index(other, _offset), do: other

  @doc """
  Mark a stored `embedding_content_hash` whose vector covers only a PREFIX of the text.
  The hash still identifies the FULL text — idempotency guards compare `whole_hash/1` —
  so the mark records truncation without re-billing the provider on every enqueue.
  `truncated_hash?/1` reads it back; `truncated_hash_pattern/0` is its SQL `LIKE` form.
  """
  @spec truncated_hash(String.t()) :: String.t()
  def truncated_hash(hash) when is_binary(hash), do: @truncated_hash_prefix <> hash

  @doc false
  def truncated_hash?(hash),
    do: is_binary(hash) and String.starts_with?(hash, @truncated_hash_prefix)

  @doc false
  def whole_hash(@truncated_hash_prefix <> hash), do: hash
  def whole_hash(hash), do: hash

  @doc false
  def truncated_hash_pattern, do: @truncated_hash_prefix <> "%"

  @doc """
  Split `items` into groups whose cumulative text stays at/under `max_bytes`, so the
  ladder is reserved for a genuinely over-long MEMBER (see the moduledoc). An item
  larger than the budget forms its own group rather than wedging into an empty one.
  """
  @spec chunk_by_bytes([item], pos_integer(), (item -> String.t())) :: [[item]] when item: term()
  def chunk_by_bytes(items, max_bytes, text_fun) do
    chunk_fun = fn item, {acc, size} ->
      len = byte_size(text_fun.(item))

      cond do
        acc == [] -> {:cont, {[item], len}}
        size + len > max_bytes -> {:cont, Enum.reverse(acc), {[item], len}}
        true -> {:cont, {[item | acc], size + len}}
      end
    end

    # `{:cont, acc}` — NOT `{:cont, [], acc}`, which emits an empty chunk for empty input.
    after_fun = fn
      {[], _size} -> {:cont, {[], 0}}
      {acc, _size} -> {:cont, Enum.reverse(acc), {[], 0}}
    end

    Enum.chunk_while(items, {[], 0}, chunk_fun, after_fun)
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
