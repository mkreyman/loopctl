defmodule Loopctl.Knowledge.ContentChunker do
  @moduledoc """
  Pure functions for splitting content into chunks for knowledge extraction.

  When content exceeds the threshold, chunks it at logical boundaries (markdown
  headings, then paragraph breaks, then byte-level if necessary) to avoid
  LLM response truncation.
  """

  require Logger

  @threshold 8_000

  @doc """
  Chunk content into pieces under the threshold, respecting markdown structure.

  Returns a list of content strings, each ideally under @threshold bytes.
  """
  def chunk(content) when byte_size(content) <= @threshold do
    [content]
  end

  def chunk(content) do
    Logger.info("ContentChunker: splitting #{byte_size(content)} bytes into chunks")

    content
    |> String.split(~r/(?=^\#{1,3}\s)/m)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> merge_sections([])
  end

  # --- Section merging (markdown-level boundaries) ---

  defp merge_sections([], acc) do
    Enum.reverse(acc)
  end

  defp merge_sections([section | rest], acc) do
    new_acc = merge_section_with_previous(section, acc)
    merge_sections(rest, new_acc)
  end

  # Try to merge section with previous chunk in accumulator
  defp merge_section_with_previous(section, []) do
    handle_oversized_section(section, [])
  end

  defp merge_section_with_previous(section, acc) do
    [last | prev_acc] = Enum.reverse(acc)
    candidate = last <> "\n" <> section

    if byte_size(candidate) <= @threshold do
      [candidate | Enum.reverse(prev_acc)]
    else
      handle_oversized_section(section, acc)
    end
  end

  # Handle section that's too large to merge
  defp handle_oversized_section(section, acc) do
    if byte_size(section) > @threshold do
      chunk_section_by_paragraph(section) ++ acc
    else
      [section | acc]
    end
  end

  # --- Paragraph-level chunking (for oversized sections) ---

  defp chunk_section_by_paragraph(section) when byte_size(section) <= @threshold do
    [section]
  end

  defp chunk_section_by_paragraph(section) do
    section
    |> String.split(~r/\n\n+/)
    |> merge_paragraphs([])
  end

  defp merge_paragraphs([], acc) do
    Enum.reverse(acc)
  end

  defp merge_paragraphs([para | rest], acc) do
    new_acc = merge_paragraph_with_previous(para, acc)
    merge_paragraphs(rest, new_acc)
  end

  # Try to merge paragraph with previous chunk
  defp merge_paragraph_with_previous(para, []) do
    handle_oversized_paragraph(para, [])
  end

  defp merge_paragraph_with_previous(para, acc) do
    [last | prev_acc] = Enum.reverse(acc)
    candidate = last <> "\n\n" <> para

    if byte_size(candidate) <= @threshold do
      [candidate | Enum.reverse(prev_acc)]
    else
      handle_oversized_paragraph(para, acc)
    end
  end

  # Handle paragraph that's too large to merge
  defp handle_oversized_paragraph(para, acc) do
    if byte_size(para) > @threshold do
      chunk_by_bytes(para, @threshold) ++ acc
    else
      [para | acc]
    end
  end

  # --- Byte-level chunking (for oversized paragraphs) ---

  defp chunk_by_bytes(text, threshold) when byte_size(text) <= threshold do
    [text]
  end

  defp chunk_by_bytes(text, threshold) do
    chunk = String.slice(text, 0, threshold)
    if chunk == "", do: [text], else: do_byte_split(text, chunk, threshold)
  end

  defp do_byte_split(text, chunk, threshold) do
    case find_split_point(chunk) do
      0 ->
        {head, tail} = String.split_at(text, threshold)
        [head | chunk_by_bytes(tail, threshold)]

      pos ->
        {head, tail} = String.split_at(text, pos)
        [String.trim_trailing(head) | chunk_by_bytes(String.trim_leading(tail), threshold)]
    end
  end

  # Find the last newline or space in the chunk for a clean break
  # Prefers newline, falls back to space
  defp find_split_point(chunk) do
    {last_newline, last_space} = find_split_point_impl(chunk, -1, -1, 0)
    best_position(last_newline, last_space)
  end

  # Scan through chunk character by character to find last newline/space
  defp find_split_point_impl(chunk, last_newline, last_space, pos) do
    case String.at(chunk, pos) do
      nil ->
        {last_newline, last_space}

      "\n" ->
        find_split_point_impl(chunk, pos, last_space, pos + 1)

      c when c in [" ", "\t", "\r"] ->
        find_split_point_impl(chunk, last_newline, pos, pos + 1)

      _other ->
        find_split_point_impl(chunk, last_newline, last_space, pos + 1)
    end
  end

  # Return the best split position: prefer newline, then space, else 0
  defp best_position(last_newline, _last_space) when last_newline >= 0, do: last_newline
  defp best_position(_last_newline, last_space) when last_space >= 0, do: last_space
  defp best_position(_last_newline, _last_space), do: 0
end
