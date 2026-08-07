defmodule Loopctl.Embeddings.ShrinkLadderTest do
  @moduledoc """
  The ladder's contract at the call sites #615 did not reach (#617).

  Every assertion here pins a property whose absence is a PERMANENT un-embedded row:
  before this module, an input-too-long rejection on the re-embed, system-corpus,
  memory and novelty-gate paths fell through to `Llm.permanent_provider_error?/1`,
  which is `true` for any 4xx — so the job DISCARDED and nothing ever retried it.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Embeddings.TextBudget

  @too_long {:error, {:api_error, 400, :context_length_exceeded}}

  # A provider that accepts anything at or under `limit` bytes and rejects the rest,
  # recording every call it was asked to make.
  defp provider(limit) do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    fun = fn text ->
      Agent.update(calls, &[byte_size(text) | &1])
      if byte_size(text) <= limit, do: {:ok, vector(text)}, else: @too_long
    end

    {fun, fn -> calls |> Agent.get(& &1) |> Enum.reverse() end}
  end

  defp batch_provider(limit) do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    fun = fn texts ->
      Agent.update(calls, &[Enum.map(texts, fn t -> byte_size(t) end) | &1])

      if Enum.all?(texts, &(byte_size(&1) <= limit)),
        do: {:ok, Enum.map(texts, &vector/1)},
        else: @too_long
    end

    {fun, fn -> calls |> Agent.get(& &1) |> Enum.reverse() end}
  end

  # A vector that identifies WHICH text produced it, so the batch tests can prove
  # alignment rather than merely counting.
  defp vector(text), do: [byte_size(text) * 1.0]

  describe "embed_one/3" do
    test "passes a successful first attempt straight through, with no extra calls" do
      {fun, calls} = provider(100_000)

      assert {:ok, _} = ShrinkLadder.embed_one("short text", fun)
      assert length(calls.()) == 1
    end

    test "shrinks until the provider accepts, and every attempt is strictly smaller" do
      text = String.duplicate("a", 60_000)
      {fun, calls} = provider(10_000)

      assert {:ok, _, :truncated} = ShrinkLadder.embed_one(text, fun)

      sent = calls.()
      assert length(sent) > 1, "the ladder never retried"
      assert sent == Enum.sort(sent, :desc) and Enum.uniq(sent) == sent
      assert List.last(sent) <= 10_000
    end

    test "an exhausted ladder returns the ORIGINAL provider error, not a synthesized one" do
      # A provider that rejects even the floor is a DIFFERENT defect (a much smaller model
      # window), and must stay legible as one instead of being absorbed by more halving.
      {fun, calls} = provider(1)

      assert ShrinkLadder.embed_one(String.duplicate("a", 40_000), fun) == @too_long

      assert List.last(calls.()) == TextBudget.floor_bytes(),
             "the floor must be TRIED exactly once before giving up"
    end

    test "a non-length error is passed through untouched and never retried" do
      # The whole point: the caller's snooze/cancel/discard handling must still see its own
      # error. Swallowing :circuit_open into a shrink loop would hot-retry a tripped breaker.
      for reason <- [:circuit_open, :no_api_key, :rate_limited_local, {:api_error, 500}] do
        {:ok, calls} = Agent.start_link(fn -> 0 end)

        fun = fn _text ->
          Agent.update(calls, &(&1 + 1))
          {:error, reason}
        end

        assert ShrinkLadder.embed_one("text", fun) == {:error, reason}
        assert Agent.get(calls, & &1) == 1, "#{inspect(reason)} was retried"
      end
    end

    test "truncation never splits a UTF-8 codepoint" do
      # The input class this exists for is multi-byte text; a cut mid-codepoint yields a
      # binary that is not a valid string and would fail at the JSON encoder instead.
      {:ok, seen} = Agent.start_link(fn -> [] end)

      fun = fn text ->
        Agent.update(seen, &[text | &1])
        if byte_size(text) <= 9_000, do: {:ok, vector(text)}, else: @too_long
      end

      assert {:ok, _, :truncated} = ShrinkLadder.embed_one(String.duplicate("щ", 20_000), fun)
      assert Enum.all?(Agent.get(seen, & &1), &String.valid?/1)
    end

    test "a shrunk vector is TAGGED :truncated and an untouched one is not" do
      # The tag is what stops `ProposalGate` calling a prefix a duplicate (dropping the
      # create) and `Memory` superseding a prior memory on one. An untagged prefix is a
      # prefix the caller compares against whole-text vectors without knowing.
      {fits, _} = provider(100_000)
      {shrinks, _} = provider(9_000)

      assert {:ok, _} = ShrinkLadder.embed_one(String.duplicate("a", 20_000), fits)
      assert {:ok, _, :truncated} = ShrinkLadder.embed_one(String.duplicate("a", 20_000), shrinks)
    end

    test ":max_rungs bounds the ladder for a SYNCHRONOUS caller" do
      # Every rung is a provider round trip and an embedding admission slot, paid inside an
      # article-create request. `ProposalGate` spends one and accepts its own fail-open.
      {fun, calls} = provider(1_000)

      assert ShrinkLadder.embed_one(String.duplicate("a", 40_000), fun, max_rungs: 1) == @too_long
      assert length(calls.()) == 2, "the rung budget was not honoured"
    end
  end

  describe "embed_batch/3" do
    test "returns vectors in INPUT order after a bisect" do
      # The caller zips these against its own entries, so a reordering silently writes each
      # article its neighbour's vector — a corruption no length check would catch.
      texts = ["a", String.duplicate("b", 50_000), "c", "d"]
      {fun, _calls} = batch_provider(20_000)

      assert {:ok, vectors, [1]} = ShrinkLadder.embed_batch(texts, fun)
      assert length(vectors) == 4
      assert Enum.at(vectors, 0) == vector("a")
      assert Enum.at(vectors, 2) == vector("c")
      assert Enum.at(vectors, 3) == vector("d")
    end

    test "truncates ONLY the offending member" do
      # Shrinking every text to fit an unknown offender would gut articles that were never
      # over the limit. That is why this bisects instead of blanket-shrinking.
      short = String.duplicate("s", 100)
      long = String.duplicate("L", 50_000)
      {fun, _calls} = batch_provider(20_000)

      # The truncated INDEX is reported, not merely the vectors: a storing caller must mark
      # that row or the corpus fills with prefix vectors indistinguishable from whole-text
      # ones, and the next comparison judges a whole text against one of them.
      assert {:ok, vectors, [1]} = ShrinkLadder.embed_batch([short, long, short], fun)

      assert Enum.at(vectors, 0) == vector(short)
      assert Enum.at(vectors, 2) == vector(short)
      assert Enum.at(vectors, 1) != vector(long), "the over-long member was not truncated"
    end

    test "an untruncated batch reports no truncation at all" do
      # The two-tuple is the caller's licence to store the vectors unmarked, so it must
      # never be returned for a batch the ladder actually shrank.
      {fun, _calls} = batch_provider(20_000)

      assert {:ok, [_, _]} = ShrinkLadder.embed_batch(["a", "b"], fun)
    end

    test "an empty batch makes no provider call" do
      {fun, calls} = batch_provider(10)

      assert ShrinkLadder.embed_batch([], fun) == {:ok, []}
      assert calls.() == []
    end

    test "a short vector array is reported as a length mismatch, never zipped" do
      fun = fn _texts -> {:ok, [[0.1]]} end

      assert ShrinkLadder.embed_batch(["a", "b"], fun) ==
               {:error, :embedding_batch_length_mismatch}
    end

    test "a batch whose offender cannot fit even at the floor surfaces the provider error" do
      {fun, _calls} = batch_provider(1)

      assert ShrinkLadder.embed_batch(["a", String.duplicate("b", 40_000)], fun) == @too_long
    end

    test "a non-length batch error is passed through without bisecting" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fun = fn _texts ->
        Agent.update(calls, &(&1 + 1))
        {:error, :circuit_open}
      end

      assert ShrinkLadder.embed_batch(["a", "b", "c", "d"], fun) == {:error, :circuit_open}
      assert Agent.get(calls, & &1) == 1, "an open breaker was fanned out into a bisect"
    end

    test "bisecting terminates on a batch where EVERY member is over-long" do
      # The pathological case: no innocent members to isolate. It must still finish, with
      # every member truncated to something the provider takes.
      texts = for _ <- 1..8, do: String.duplicate("x", 40_000)
      {fun, _calls} = batch_provider(9_000)

      assert {:ok, vectors, truncated} = ShrinkLadder.embed_batch(texts, fun)
      assert length(vectors) == 8
      assert truncated == Enum.to_list(0..7), "a truncated member went unreported"
    end

    test "the default call budget never gives up on work the bisect could have finished" do
      # The bisect's own worst case is ~2n-1 calls. A fixed 64 abandoned a 40-member batch
      # of over-long texts mid-bisect and surfaced the 4xx, which the callers classify as
      # PERMANENT — the job discards and the rows stay un-embedded, the outage the ladder
      # exists to end. The default therefore scales with the batch.
      texts = for _ <- 1..40, do: String.duplicate("x", 40_000)
      {fun, _calls} = batch_provider(9_000)

      assert {:ok, vectors, _truncated} = ShrinkLadder.embed_batch(texts, fun)
      assert length(vectors) == 40
    end

    test ":max_calls bounds what one already-failing batch may spend" do
      # With k over-long members the bisect is O(n), not the ~2*log2(n) a single offender
      # costs — hundreds of sequential provider calls inside one Oban job. Past the budget
      # it surfaces the provider error, exactly as an exhausted rung does.
      texts = for _ <- 1..16, do: String.duplicate("x", 40_000)
      {fun, calls} = batch_provider(9_000)

      assert ShrinkLadder.embed_batch(texts, fun, max_calls: 5) == @too_long
      assert length(calls.()) <= 5
    end
  end

  describe "chunk_by_bytes/3" do
    test "splits by CUMULATIVE bytes, so no array call is rejected on aggregate size" do
      # An aggregate rejection names no member, so every half is rejected too and the whole
      # batch pays the bisect tree on EVERY run. Callers pre-split instead.
      items = for i <- 1..6, do: {i, String.duplicate("a", 400)}

      chunks = ShrinkLadder.chunk_by_bytes(items, 1_000, fn {_i, text} -> text end)

      assert Enum.map(chunks, &length/1) == [2, 2, 2]
      assert Enum.concat(chunks) == items
    end

    test "an item bigger than the budget forms its own chunk rather than wedging" do
      items = [{1, "aa"}, {2, String.duplicate("b", 5_000)}, {3, "cc"}]

      assert [[{1, _}], [{2, _}], [{3, _}]] =
               ShrinkLadder.chunk_by_bytes(items, 10, fn {_i, text} -> text end)
    end
  end
end
