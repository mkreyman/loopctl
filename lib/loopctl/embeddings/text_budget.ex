defmodule Loopctl.Embeddings.TextBudget do
  @moduledoc """
  The shrink ladder the embedding workers walk when a provider rejects an input as
  too long, expressed in BYTES — plus the first attempt's cap, which is not.

  ## Why a ladder, and why its rungs are bytes

  Embedding models bound their input in TOKENS (OpenAI's `text-embedding-3-*`:
  8192). The workers bounded it in CHARACTERS — 32,000 of them — and the ratio
  between the two is not a constant. English prose runs ~4 chars/token, so 32,000
  chars lands just under the limit; Cyrillic, CJK, dense index pages and code run
  2-3x worse, so the same 32,000 chars is several times over it.

  Measured on the hosted corpus 2026-08-06: 80 published articles could NEVER be
  embedded. Every one returned

      400 Invalid 'input': maximum context length is 8192 tokens.

  and the hourly `EmbeddingReconciliationWorker` re-enqueued all 80 every hour,
  forever, because a permanently-discarded job leaves the gap it was meant to
  close. Those articles had been invisible to semantic search since June.

  The LADDER is the fix. Its rungs are bytes because bytes bound tokens FROM ABOVE —
  a BPE token is a merge of one or more bytes, so

      tokens(text) <= byte_size(text)

  always, for any script. Each rung is therefore a strictly tighter TOKEN bound than
  the attempt that was just rejected, without a tokenizer dependency.

  ## The first attempt is deliberately NOT byte-capped

  `initial/1` cuts at 32,000 CHARACTERS, exactly as before the ladder existed.
  Capping the first attempt in bytes instead would silently shorten multi-byte
  articles that were ALREADY embedding fine: Russian prose runs ~6 bytes/token, so a
  45,000-byte article is only ~7,500 tokens — under the limit — and a 32,000-byte cap
  would drop a third of it with no error and no log line, degrading its search recall
  invisibly. Truncation is paid only by an input the provider actually rejected; the
  bound is discovered, not assumed.

  ## The ladder

      <bytes actually sent> -> 32,000 -> 16,000 -> 8,000 -> :exhausted

  Every rung is derived from the bytes ACTUALLY SENT, never from a nominal budget: a
  budget above the text's own size truncates nothing, so halving the budget alone can
  re-send a byte-identical request and buy an identical rejection.

  `:exhausted` is a real outcome, not a loop guard for show. `floor_bytes/0` is 8,000,
  under the 8,192-token window of the models loopctl ships against — but that window
  is a property of THOSE models, not of every endpoint. `EmbeddingClient` resolves
  model and base_url per tenant, and a self-hosted 512-token embedder (bge-*, e5-*)
  rejects the floor too. `:exhausted` is how that surfaces: the caller discards it
  legibly as a different defect, rather than halving forever or storing a prefix.
  """

  # The FIRST attempt, in characters — unchanged from the cap that predates the
  # ladder, so nothing the provider was already accepting is silently shortened.
  @initial_chars 32_000

  # The largest BYTE rung the ladder drops to once an attempt has been rejected.
  @top_rung_bytes 32_000

  # Provably <= 8,000 tokens for any input, under any BPE tokenizer (see moduledoc).
  @floor_bytes 8_000

  @doc "Characters the first embedding attempt may send."
  @spec initial_chars() :: pos_integer()
  def initial_chars, do: @initial_chars

  @doc "The first attempt's text: the pre-ladder character cap, applied verbatim."
  @spec initial(String.t()) :: String.t()
  def initial(text) when is_binary(text), do: String.slice(text, 0, @initial_chars)

  @doc "The largest byte rung the ladder drops to after a rejection."
  @spec top_rung_bytes() :: pos_integer()
  def top_rung_bytes, do: @top_rung_bytes

  @doc "The smallest budget the ladder will try."
  @spec floor_bytes() :: pos_integer()
  def floor_bytes, do: @floor_bytes

  @doc """
  The next budget below `sent_bytes`, or `:exhausted` once the floor has been tried.

  Keyed to what was ACTUALLY SENT, so every rung is strictly smaller than the attempt
  it replaces. Halves, capped at the top rung and clamped at the floor — so the ladder
  visits the floor exactly once and then stops, rather than converging on it forever.
  """
  @spec next_budget(non_neg_integer()) :: pos_integer() | :exhausted
  def next_budget(sent_bytes) when is_integer(sent_bytes) and sent_bytes <= @floor_bytes,
    do: :exhausted

  def next_budget(sent_bytes) when is_integer(sent_bytes),
    do: sent_bytes |> div(2) |> min(@top_rung_bytes) |> max(@floor_bytes)

  @doc """
  Truncate `text` to at most `max_bytes`, never splitting a UTF-8 codepoint.

  `binary_part/3` cuts on a byte boundary, which for multi-byte text can leave a
  partial codepoint that is not a valid string — the exact input class this module
  exists for. The tail is trimmed until the result is valid again (at most 3 bytes,
  since no UTF-8 codepoint is longer than 4).
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  def truncate(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    text |> binary_part(0, max_bytes) |> trim_partial_codepoint()
  end

  defp trim_partial_codepoint(<<>>), do: <<>>

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
