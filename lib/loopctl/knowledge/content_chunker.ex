defmodule Loopctl.Knowledge.ContentChunker do
  @moduledoc """
  Pure functions for splitting content into chunks for knowledge extraction.

  When content exceeds the byte threshold, chunks it at logical boundaries
  (markdown headings, then paragraph breaks, then byte-level fallback) to
  avoid LLM response truncation.

  ## Invariants

  - Returned chunks preserve the original content order.
  - `byte_size(chunk) <= threshold` for every chunk, unless a single atomic
    unit (paragraph with no whitespace) exceeds threshold, in which case the
    chunker force-splits on byte boundaries at the last safe UTF-8 codepoint
    break.
  - Adjacent small sections may be merged together; non-adjacent sections
    are NEVER merged.
  - `chunk/1` is pure (no IO, no external state).
  """

  require Logger

  @threshold 8_000

  @doc """
  Chunk content into pieces under the threshold, respecting markdown structure.

  Returns a list of content strings in the original order, each at most
  `@threshold` bytes unless a single unbreakable unit exceeds that size.
  """
  @spec chunk(binary()) :: [binary()]
  def chunk(content) when byte_size(content) <= @threshold do
    [content]
  end

  def chunk(content) do
    Logger.debug("ContentChunker: splitting #{byte_size(content)} bytes")

    content
    |> String.split(~r/(?=^\#{1,3}\s)/m)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> merge_units(@threshold, "\n")
  end

  # --- Generic merge for sections and paragraphs ---
  #
  # Walks units in order, keeping a `pending` buffer of the current chunk
  # being assembled. When appending the next unit would overflow threshold,
  # the pending buffer is flushed to `finalized` (prepended — finalized is
  # in reverse order for O(1) prepend) and the new unit becomes pending.
  #
  # Oversized units (individually > threshold) flush pending first, then
  # sub-chunk the unit using the next-smaller boundary (paragraph, then byte).

  defp merge_units(units, threshold, joiner) do
    {finalized, pending} =
      Enum.reduce(units, {[], nil}, &reduce_unit(&1, &2, threshold, joiner))

    finalized = if pending, do: [pending | finalized], else: finalized
    Enum.reverse(finalized)
  end

  # One reduction step for merge_units/3. Split out to keep credo happy
  # about nesting depth.
  defp reduce_unit(unit, {finalized, pending}, threshold, joiner)
       when byte_size(unit) > threshold do
    finalized = if pending, do: [pending | finalized], else: finalized
    sub_chunks = sub_chunk(unit, threshold, joiner)
    # Prepend sub_chunks reversed so finalized stays in reverse-order invariant
    {Enum.reverse(sub_chunks) ++ finalized, nil}
  end

  defp reduce_unit(unit, {finalized, nil}, _threshold, _joiner) do
    {finalized, unit}
  end

  defp reduce_unit(unit, {finalized, pending}, threshold, joiner) do
    candidate = pending <> joiner <> unit

    if byte_size(candidate) <= threshold do
      {finalized, candidate}
    else
      {[pending | finalized], unit}
    end
  end

  # Sub-chunk an oversized unit at the next-finer boundary.
  # Sections fall back to paragraphs; paragraphs fall back to byte-level.
  defp sub_chunk(unit, threshold, "\n") do
    # Oversized section: split by blank lines (paragraphs) and re-merge
    unit
    |> String.split(~r/\n\n+/)
    |> merge_units(threshold, "\n\n")
  end

  defp sub_chunk(unit, threshold, "\n\n") do
    # Oversized paragraph: fall through to byte-level split
    chunk_by_bytes(unit, threshold)
  end

  # --- Byte-level chunking (for oversized paragraphs) ---
  #
  # Splits on byte boundaries at the last safe UTF-8 codepoint break,
  # preferring a newline or space for readability. Guarantees each emitted
  # chunk satisfies `byte_size(chunk) <= threshold`.

  defp chunk_by_bytes(text, threshold) when byte_size(text) <= threshold do
    [text]
  end

  defp chunk_by_bytes(text, threshold) do
    split_at = find_byte_split_point(text, threshold)
    <<head::binary-size(split_at), tail::binary>> = text
    [String.trim_trailing(head) | chunk_by_bytes(String.trim_leading(tail), threshold)]
  end

  # Find the latest safe byte offset at or before `max_bytes` where we can
  # split `text`. Safe means: on a UTF-8 codepoint boundary, preferring
  # (in order) the last newline, then the last space, then the latest
  # codepoint boundary.
  defp find_byte_split_point(text, max_bytes) do
    end_pos = min(max_bytes, byte_size(text))
    head = :binary.part(text, 0, end_pos)

    # Prefer last newline (always on a codepoint boundary since "\n" is ASCII)
    case :binary.matches(head, "\n") do
      [] ->
        case :binary.matches(head, " ") do
          [] -> safe_utf8_boundary(text, end_pos)
          matches -> boundary_after_last_match(matches, end_pos)
        end

      matches ->
        boundary_after_last_match(matches, end_pos)
    end
  end

  # `matches` is a non-empty list of {pos, len} tuples. Split AFTER the
  # last match (so the delimiter stays with the head).
  defp boundary_after_last_match(matches, fallback) do
    {pos, len} = List.last(matches)
    candidate = pos + len
    if candidate > 0, do: candidate, else: fallback
  end

  # Walk back from `pos` in the ORIGINAL text until we find a byte that
  # is NOT a UTF-8 continuation byte (0b10xxxxxx). That byte is the start
  # of a codepoint, so splitting immediately before it is safe.
  defp safe_utf8_boundary(_text, pos) when pos <= 0, do: 0

  defp safe_utf8_boundary(text, pos) when pos >= byte_size(text) do
    byte_size(text)
  end

  defp safe_utf8_boundary(text, pos) do
    case :binary.at(text, pos) do
      byte when Bitwise.band(byte, 0xC0) == 0x80 ->
        safe_utf8_boundary(text, pos - 1)

      _ ->
        pos
    end
  end
end
