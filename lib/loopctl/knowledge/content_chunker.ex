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
    |> normalize_headings()
    |> String.split(~r/(?=^\#{1,6}\s)/m)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> merge_units(@threshold, :section)
    |> Enum.reject(&(&1 == ""))
  end

  # Ensure markdown headings always start on a fresh line. Without this,
  # `# B` embedded mid-line (no preceding newline) is invisible to the
  # multiline `^#` anchor, so the chunker would treat two separate sections
  # as one mega-section and force byte-level fallback.
  defp normalize_headings(content) do
    Regex.replace(~r/([^\n])(\n\#{1,6}\s)/, content, "\\1\n\\2")
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

  defp merge_units(units, threshold, level) do
    {finalized, pending} =
      Enum.reduce(units, {[], nil}, &reduce_unit(&1, &2, threshold, level))

    finalized = if pending, do: [pending | finalized], else: finalized
    Enum.reverse(finalized)
  end

  # One reduction step for merge_units/3. Split out to keep credo happy
  # about nesting depth.
  defp reduce_unit(unit, {finalized, pending}, threshold, level)
       when byte_size(unit) > threshold do
    finalized = if pending, do: [pending | finalized], else: finalized
    sub_chunks = sub_chunk(unit, threshold, level)
    # Prepend sub_chunks reversed so finalized stays in reverse-order invariant
    {Enum.reverse(sub_chunks) ++ finalized, nil}
  end

  defp reduce_unit(unit, {finalized, nil}, _threshold, _level) do
    {finalized, unit}
  end

  defp reduce_unit(unit, {finalized, pending}, threshold, level) do
    candidate = pending <> joiner_for(level) <> unit

    if byte_size(candidate) <= threshold do
      {finalized, candidate}
    else
      {[pending | finalized], unit}
    end
  end

  defp joiner_for(:section), do: "\n"
  defp joiner_for(:paragraph), do: "\n\n"

  # Sub-chunk an oversized unit at the next-finer boundary.
  # Sections fall back to paragraphs; paragraphs fall back to byte-level.
  # The `level` atom makes the fall-through explicit (earlier versions
  # switched on the joiner string, which was fragile).
  defp sub_chunk(unit, threshold, :section) do
    unit
    |> String.split(~r/\n\n+/)
    |> merge_units(threshold, :paragraph)
  end

  defp sub_chunk(unit, threshold, :paragraph) do
    chunk_by_bytes(unit, threshold)
  end

  # --- Byte-level chunking (for oversized paragraphs) ---
  #
  # Splits on byte boundaries, preferring a clean break at a newline or
  # space near the end of the allowed range. Guarantees each emitted chunk
  # satisfies `byte_size(chunk) <= threshold` AND makes forward progress
  # on every iteration (no infinite loops on pathological input like a
  # stream of raw UTF-8 continuation bytes).

  defp chunk_by_bytes(text, threshold) when byte_size(text) <= threshold do
    [text]
  end

  defp chunk_by_bytes(text, threshold) do
    split_at = find_byte_split_point(text, threshold)
    <<head::binary-size(split_at), tail::binary>> = text
    [String.trim_trailing(head) | chunk_by_bytes(String.trim_leading(tail), threshold)]
  end

  # Find a safe byte offset <= `max_bytes` at which to split `text`. The
  # return value is guaranteed to be in the range `[1, max_bytes]` as long
  # as `byte_size(text) > max_bytes`, so `chunk_by_bytes` always makes
  # forward progress.
  #
  # Preference order:
  # 1. The NEAR (within the last quarter of the range) whitespace
  #    boundary — newline beats space when both are available.
  # 2. If no near whitespace exists, the safest UTF-8 codepoint boundary.
  # 3. If neither works (e.g., adversarial input with no codepoint start
  #    in the first max_bytes — a stream of continuation bytes), hard
  #    split at max_bytes regardless. Producing a potentially-invalid
  #    chunk is preferable to an infinite loop, and downstream code must
  #    tolerate garbage anyway.
  @min_preferred_boundary_ratio 0.75

  defp find_byte_split_point(text, max_bytes) do
    end_pos = min(max_bytes, byte_size(text))
    head = :binary.part(text, 0, end_pos)
    min_accept = trunc(end_pos * @min_preferred_boundary_ratio)

    prefer_whitespace_boundary(head, end_pos, min_accept) ||
      utf8_boundary_or_force(text, end_pos)
  end

  # Try to find a newline or space boundary >= min_accept, preferring the
  # latest one. Returns nil if no acceptable match is found.
  defp prefer_whitespace_boundary(head, end_pos, min_accept) do
    newline_pos = last_match_boundary(:binary.matches(head, "\n"), min_accept, end_pos)
    space_pos = last_match_boundary(:binary.matches(head, " "), min_accept, end_pos)

    cond do
      newline_pos && newline_pos >= min_accept -> newline_pos
      space_pos && space_pos >= min_accept -> space_pos
      true -> nil
    end
  end

  # From a list of `:binary.matches` results, return the boundary AFTER
  # the last match that is <= end_pos, or nil if none exist.
  defp last_match_boundary([], _min_accept, _end_pos), do: nil

  defp last_match_boundary(matches, _min_accept, end_pos) do
    matches
    |> Enum.map(fn {pos, len} -> pos + len end)
    |> Enum.filter(&(&1 <= end_pos))
    |> Enum.max(fn -> nil end)
  end

  # Fall back to the latest safe UTF-8 codepoint boundary. If even that
  # returns 0 (pathological input), force a hard split at end_pos to
  # guarantee forward progress.
  defp utf8_boundary_or_force(text, end_pos) do
    case safe_utf8_boundary(text, end_pos) do
      0 -> end_pos
      pos -> pos
    end
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
