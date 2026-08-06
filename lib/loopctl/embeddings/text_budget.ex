defmodule Loopctl.Embeddings.TextBudget do
  @moduledoc """
  The size budget for text sent to an embedding provider, expressed in BYTES, plus
  the shrink ladder the embedding workers walk when the provider rejects an input
  as too long.

  ## Why bytes, and why a ladder

  Embedding models bound their input in TOKENS (OpenAI's `text-embedding-3-*`:
  8192). The workers used to bound it in CHARACTERS — 32,000 of them — and the
  ratio between the two is not a constant. English prose runs ~4 chars/token, so
  32,000 chars lands just under the limit; Cyrillic, CJK, dense index pages and
  code run 2-3x worse, so the same 32,000 chars is several times over it.

  Measured on the hosted corpus 2026-08-06: 80 published articles could NEVER be
  embedded. Every one returned

      400 Invalid 'input': maximum context length is 8192 tokens.

  and the hourly `EmbeddingReconciliationWorker` re-enqueued all 80 every hour,
  forever, because a permanently-discarded job leaves the gap it was meant to
  close. Those articles had been invisible to semantic search since June. A
  character cap is not a token bound.

  Bytes are not a token bound either — but they are a token BOUND FROM ABOVE, which
  characters are not. A BPE token is a merge of one or more bytes, so

      tokens(text) <= byte_size(text)

  always, for any script. That inequality is what makes `floor_bytes/0` a proof
  rather than an estimate: 8,000 bytes cannot tokenize to more than 8,000 tokens,
  which is under every limit we send to. So the ladder is guaranteed to terminate
  in a value the provider accepts, without a tokenizer dependency.

  Starting AT the floor would be the simple fix and it is the wrong one: 8,000
  bytes of English is ~2,000 tokens, so every article in the corpus would embed a
  quarter of its content to accommodate the 0.1% that overflow. Instead the first
  attempt stays generous (`initial_bytes/0`) and only an input the provider
  actually rejects pays for a retry. The bound is discovered, not assumed — the
  provider's 400 is the measurement.

  ## The ladder

      32,000 -> 16,000 -> 8,000 -> :exhausted

  Two retries at most, and only for text that overflowed. `:exhausted` is a real
  outcome, not a loop guard for show: it means the floor itself was rejected, which
  can only be a DIFFERENT defect (a changed model, a much smaller limit) and must
  surface as a discard rather than as endless halving.
  """

  # Unchanged from the character cap it replaces, so an ASCII article — the bulk of
  # the corpus — sends exactly what it sent before. Multi-byte text is bounded more
  # tightly at the same number, which is the population that was failing.
  @initial_bytes 32_000

  # Provably <= 8,000 tokens for any input, under any BPE tokenizer (see moduledoc).
  @floor_bytes 8_000

  @doc "Bytes the first embedding attempt may send."
  @spec initial_bytes() :: pos_integer()
  def initial_bytes, do: @initial_bytes

  @doc "The smallest budget the ladder will try; provably under every token limit."
  @spec floor_bytes() :: pos_integer()
  def floor_bytes, do: @floor_bytes

  @doc """
  The next budget down, or `:exhausted` once the floor has already been tried.

  Halves, clamped at the floor — so the ladder visits the floor exactly once and
  then stops, rather than converging on it forever.
  """
  @spec shrink(pos_integer()) :: pos_integer() | :exhausted
  def shrink(bytes) when is_integer(bytes) and bytes <= @floor_bytes, do: :exhausted
  def shrink(bytes) when is_integer(bytes), do: max(div(bytes, 2), @floor_bytes)

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
