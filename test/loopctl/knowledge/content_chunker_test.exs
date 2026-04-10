defmodule Loopctl.Knowledge.ContentChunkerTest do
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ContentChunker

  @threshold 8_000

  describe "chunk/1 — small content" do
    test "returns a single chunk when content is under threshold" do
      content = "Short article body that fits in one chunk."
      assert ContentChunker.chunk(content) == [content]
    end

    test "returns empty string unchanged" do
      assert ContentChunker.chunk("") == [""]
    end
  end

  describe "chunk/1 — section merging and ordering" do
    test "preserves section order when splitting and merging" do
      # Build three markdown sections; individually small enough to merge
      # in pairs but forcing chunking.
      section_a = "# A\n" <> String.duplicate("alpha ", 700)
      section_b = "# B\n" <> String.duplicate("beta ", 700)
      section_c = "# C\n" <> String.duplicate("gamma ", 700)
      content = section_a <> section_b <> section_c

      chunks = ContentChunker.chunk(content)

      # Every chunk must be under the threshold
      for chunk <- chunks do
        assert byte_size(chunk) <= @threshold,
               "chunk exceeds threshold: #{byte_size(chunk)}"
      end

      # Join order must be equivalent to original (not reversed, not jumbled)
      # We verify that section A content appears before B content appears
      # before C content in the concatenated output.
      joined = Enum.join(chunks, "\n")
      a_pos = :binary.match(joined, "alpha") |> elem(0)
      b_pos = :binary.match(joined, "beta") |> elem(0)
      c_pos = :binary.match(joined, "gamma") |> elem(0)
      assert a_pos < b_pos, "section A should come before B (got A=#{a_pos} B=#{b_pos})"
      assert b_pos < c_pos, "section B should come before C (got B=#{b_pos} C=#{c_pos})"
    end

    test "never merges non-adjacent sections when middle section is oversized" do
      # Small A + oversized B + small C.
      # The critical bug was that A and C got merged together (skipping B)
      # because the accumulator was walked in reverse order.
      small_a = "# Section A\nAlpha content here.\n"
      # Build an oversized section B with paragraph breaks so it sub-chunks
      big_b =
        "# Section B\n" <>
          Enum.map_join(1..8, "\n\n", fn i ->
            "Paragraph #{i}: " <> String.duplicate("beta ", 300)
          end)

      small_c = "# Section C\nGamma content here.\n"

      content = small_a <> big_b <> small_c

      chunks = ContentChunker.chunk(content)

      for chunk <- chunks do
        assert byte_size(chunk) <= @threshold,
               "chunk exceeds threshold: #{byte_size(chunk)}"
      end

      # A chunk containing Alpha must NOT also contain Gamma — they are
      # non-adjacent in the source (B is between them).
      merged_a_and_c =
        Enum.any?(chunks, fn chunk ->
          String.contains?(chunk, "Alpha content") and String.contains?(chunk, "Gamma content")
        end)

      refute merged_a_and_c,
             "non-adjacent sections A and C must not be merged into the same chunk"

      # Order must still be preserved: Alpha must appear before Gamma
      joined = Enum.join(chunks, "\n")
      a_pos = :binary.match(joined, "Alpha content") |> elem(0)
      c_pos = :binary.match(joined, "Gamma content") |> elem(0)
      assert a_pos < c_pos, "Alpha must appear before Gamma in the output"
    end

    test "preserves paragraph order within an oversized section" do
      # One section with many paragraphs — verify their relative order survives
      paragraphs =
        Enum.map(1..6, fn i -> "Paragraph #{i}: " <> String.duplicate("x", 2000) end)

      content = "# Big Section\n" <> Enum.join(paragraphs, "\n\n")

      chunks = ContentChunker.chunk(content)
      joined = Enum.join(chunks, "\n")

      positions =
        for i <- 1..6 do
          {i, :binary.match(joined, "Paragraph #{i}:") |> elem(0)}
        end

      sorted = Enum.sort_by(positions, fn {_i, pos} -> pos end)
      assert sorted == positions, "paragraph order not preserved: #{inspect(sorted)}"
    end
  end

  describe "chunk/1 — byte-level fallback" do
    test "splits a single oversized paragraph with no internal whitespace" do
      # Pathological: one paragraph > threshold with no spaces or newlines.
      content = String.duplicate("x", @threshold * 2 + 100)

      chunks = ContentChunker.chunk(content)

      for chunk <- chunks do
        assert byte_size(chunk) <= @threshold,
               "chunk exceeds threshold: #{byte_size(chunk)}"
      end

      # Total byte content (modulo whitespace trimming) is preserved.
      total = chunks |> Enum.map(&byte_size/1) |> Enum.sum()
      assert total >= byte_size(content) - 10
    end

    test "preserves UTF-8 codepoint boundaries when byte-splitting" do
      # 4-byte emoji characters repeated until we overflow the threshold
      # with no whitespace. Byte-splitting must not land mid-codepoint.
      emoji = "😀"
      count = div(@threshold, byte_size(emoji)) + 50
      content = String.duplicate(emoji, count)

      chunks = ContentChunker.chunk(content)

      for chunk <- chunks do
        assert byte_size(chunk) <= @threshold
        # Each chunk must be valid UTF-8 — String.valid?/1 returns false
        # if any codepoint was split.
        assert String.valid?(chunk), "chunk is not valid UTF-8"
      end
    end
  end

  describe "chunk/1 — invariants" do
    test "all chunks under or equal to threshold for realistic mixed content" do
      # Mix of markdown sections, paragraphs, and long code blocks
      content = """
      # Introduction
      #{String.duplicate("intro ", 500)}

      ## Details
      #{String.duplicate("detail ", 600)}

      Another paragraph with lots of content. #{String.duplicate("x", 3000)}

      ## Section Two
      #{String.duplicate("section ", 700)}

      Final thoughts. #{String.duplicate("final ", 200)}
      """

      chunks = ContentChunker.chunk(content)

      for chunk <- chunks do
        assert byte_size(chunk) <= @threshold,
               "chunk exceeds threshold: #{byte_size(chunk)}"
      end

      # Content should not be lost — total chunk bytes is close to input
      # (allowing for trimmed whitespace and joiner differences).
      input_size = byte_size(content)
      total = chunks |> Enum.map(&byte_size/1) |> Enum.sum()
      assert total >= input_size - 20 * length(chunks)
    end
  end
end
