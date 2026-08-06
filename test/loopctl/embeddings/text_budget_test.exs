defmodule Loopctl.Embeddings.TextBudgetTest do
  @moduledoc """
  The budget's contract is a TERMINATION PROOF, not a preference: the ladder must
  reach a rung that no tokenizer can push over the provider's limit, and it must
  stop there rather than halving forever.

  These tests are written against the corpus that broke it — 80 published articles
  the old 32,000-CHARACTER cap could never embed, because characters do not bound
  tokens. Each one pins a property that, if it regressed, would put those articles
  back into the hourly retry loop.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Embeddings.TextBudget

  describe "the ladder terminates" do
    test "shrink/1 reaches the floor and then reports exhaustion" do
      rungs =
        Stream.unfold(TextBudget.initial_bytes(), fn
          :exhausted -> nil
          budget -> {budget, TextBudget.shrink(budget)}
        end)
        |> Enum.take(50)

      assert List.last(rungs) == TextBudget.floor_bytes(),
             "the ladder must END at the floor, not merely approach it"

      assert TextBudget.shrink(TextBudget.floor_bytes()) == :exhausted

      # The real guarantee: bounded, and small. Two retries, not fifty.
      assert length(rungs) <= 4, "ladder should be a handful of rungs, got #{length(rungs)}"
    end

    test "shrink/1 below the floor is exhausted, never a smaller positive budget" do
      # A budget under the floor can only arise from a caller bug; halving it further
      # would send ever-tinier prefixes to a paid provider instead of failing loudly.
      assert TextBudget.shrink(1) == :exhausted
      assert TextBudget.shrink(TextBudget.floor_bytes() - 1) == :exhausted
    end
  end

  describe "the floor is a bound, not an estimate" do
    test "floor is under the smallest provider limit we send to" do
      # A BPE token is a merge of one or more BYTES, so tokens <= byte_size always.
      # That inequality is the whole reason the floor is expressible in bytes.
      # OpenAI text-embedding-3-* caps at 8192 tokens.
      assert TextBudget.floor_bytes() < 8192
    end

    test "the initial budget is generous enough not to gut ordinary articles" do
      # Starting AT the floor would be the trivial fix and the wrong one: it would
      # truncate every article in the corpus to fix the 0.1% that overflow.
      assert TextBudget.initial_bytes() >= 4 * TextBudget.floor_bytes()
    end
  end

  describe "truncate/2" do
    test "returns text under budget untouched" do
      assert TextBudget.truncate("short", 100) == "short"
    end

    test "bounds BYTES, not characters — the whole point of the change" do
      # Cyrillic is 2 bytes/char. Under the old character cap this text counted as
      # 100 "characters" and sailed through; it is 200 bytes.
      text = String.duplicate("я", 100)
      assert String.length(text) == 100
      assert byte_size(text) == 200

      out = TextBudget.truncate(text, 50)
      assert byte_size(out) <= 50

      refute String.length(out) == 100,
             "a character-based cap would have returned this unchanged"
    end

    test "never splits a UTF-8 codepoint" do
      # Cut at every byte offset across a mix of 1-, 2-, 3- and 4-byte codepoints.
      # A naive binary_part/3 produces an invalid string at most of these offsets.
      text = "aя€🎯" |> String.duplicate(20)

      for max_bytes <- 1..byte_size(text) do
        out = TextBudget.truncate(text, max_bytes)

        assert String.valid?(out),
               "truncating to #{max_bytes} bytes produced an invalid UTF-8 string"

        assert byte_size(out) <= max_bytes,
               "truncating to #{max_bytes} bytes returned #{byte_size(out)} bytes"
      end
    end

    test "a 4-byte codepoint at the boundary is dropped whole, not clipped" do
      # 🎯 is 4 bytes. Asking for 2 must yield "" — not two bytes of a codepoint.
      assert TextBudget.truncate("🎯", 2) == ""
      assert TextBudget.truncate("🎯", 4) == "🎯"
    end

    test "output at the floor cannot exceed the token limit for ANY script" do
      # The property the floor rests on, asserted directly on the worst input we can
      # construct: every codepoint 4 bytes.
      text = String.duplicate("🎯", 10_000)
      out = TextBudget.truncate(text, TextBudget.floor_bytes())

      assert byte_size(out) <= TextBudget.floor_bytes()
      assert byte_size(out) < 8192, "tokens <= bytes, so bytes < 8192 implies tokens < 8192"
    end
  end
end
