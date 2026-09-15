defmodule Loopctl.Memory.AnswerConfidenceTest do
  @moduledoc """
  The recall no-answer verdict (#742), tested on the pools a real recall cannot stage on
  demand: a field where half the rows scored zero, a row with no score at all, and a curated
  winner that diversity dropped before the caller saw it.

  Every one of these was a review finding, and each one shipped green because the end-to-end
  test could not arrange the condition. Testing the rule where it lives is what makes them
  falsifiable — `test/loopctl/memory_recall_context_test.exs` keeps the end-to-end half.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Memory.AnswerConfidence

  defp knowledge(score),
    do: %{source: :knowledge, score: score, article: %{id: Ecto.UUID.generate()}}

  defp memory(score), do: %{source: :memory, score: score}
  defp retrieved, do: %{meta: %{provenance: :retrieved, confidence: 0.4}}

  describe "what the verdict is about" do
    test "MEMORY ROWS ARE NOT READ, whatever they score" do
      # THE HIGH FINDING. Memory is raw cosine with a high floor (~0.3-0.8 for anything);
      # a keyword-only knowledge row is raw/(raw+1) of ts_rank_cd (~0.02-0.2). Judged
      # together, one loosely-related memory against a flat knowledge field is a ratio of
      # ten and reads `:answer` by construction — the failure this exists to prevent.
      flat_knowledge = [knowledge(0.05), knowledge(0.05), knowledge(0.05)]

      assert AnswerConfidence.verdict(retrieved(), flat_knowledge) == :weak

      # The same knowledge field, with a memory row towering over it. The verdict must not
      # move: a memory row is the agent's own prior statement, not evidence about the corpus.
      assert AnswerConfidence.verdict(retrieved(), [memory(0.55) | flat_knowledge]) == :weak
    end

    test "no knowledge rows is :none even when memory answered" do
      # `:none` means the KNOWLEDGE half returned nothing, which is what the schema says.
      assert AnswerConfidence.verdict(retrieved(), []) == :none
      assert AnswerConfidence.verdict(retrieved(), [memory(0.9), memory(0.8)]) == :none
    end
  end

  describe "separation" do
    test "a top that stands apart from the field is an answer" do
      assert AnswerConfidence.verdict(retrieved(), [
               knowledge(0.8),
               knowledge(0.2),
               knowledge(0.2)
             ]) == :answer
    end

    test "a flat field is weak" do
      assert AnswerConfidence.verdict(retrieved(), [
               knowledge(0.42),
               knowledge(0.40),
               knowledge(0.38)
             ]) == :weak
    end

    test "a lone row is weak, so the verdict cannot depend on the caller's limit" do
      assert AnswerConfidence.verdict(retrieved(), [knowledge(0.99)]) == :weak
    end

    test "A ZERO MEDIAN IS A DEGRADED POOL, NOT AN EMPTY FIELD" do
      # The worst finding of the round. Half the field scoring zero was read as "there is no
      # field behind the top" — and during an embedding outage BOTH halves degrade together,
      # so the single most degraded response the endpoint can produce shipped the strongest
      # possible verdict. A field that scored nothing supports no claim about the row above.
      assert AnswerConfidence.verdict(retrieved(), [
               knowledge(0.3),
               knowledge(0.0),
               knowledge(0.0),
               knowledge(0.0)
             ]) == :weak
    end

    test "an UNSCORED row is excluded from the field, not counted as the bottom of it" do
      # Unmeasurable is not irrelevant — the same distinction the diversity selector draws
      # when it refuses to drop a vector-less candidate as a duplicate. Counted as zero, one
      # unscored row drags the median down and flips a flat field into an answer.
      flat = [knowledge(0.50), knowledge(0.45)]
      assert AnswerConfidence.verdict(retrieved(), flat) == :weak

      unscored = %{source: :knowledge, article: %{id: Ecto.UUID.generate()}}
      assert AnswerConfidence.verdict(retrieved(), flat ++ [unscored]) == :weak
    end
  end

  describe "curated" do
    test "a curated winner that is PRESENT is an answer" do
      id = Ecto.UUID.generate()
      env = %{meta: %{provenance: :curated, curated_article_id: id}}
      rows = [%{source: :knowledge, score: 0.4, article: %{id: id}}, knowledge(0.39)]

      assert AnswerConfidence.verdict(env, rows) == :answer
    end

    test "a curated winner that DIVERSITY DROPPED is not an answer" do
      # `hybrid_search/3` pins its winner through selection with `:preselected` so a caller
      # branching on `provenance` can trust the first row. The merged recall does not pin it:
      # the winner can be dropped as a near-duplicate, excluded by the recall history cache,
      # or re-sorted and cut by the merged limit. Publishing "a governed article answers
      # this" while that article is absent is a worse lie than a weak verdict.
      env = %{meta: %{provenance: :curated, curated_article_id: Ecto.UUID.generate()}}

      assert AnswerConfidence.verdict(env, [knowledge(0.42), knowledge(0.40)]) == :weak
    end

    test "curated with NO id named falls through to separation rather than asserting" do
      env = %{meta: %{provenance: :curated, curated_article_id: nil}}

      assert AnswerConfidence.verdict(env, [knowledge(0.42), knowledge(0.40)]) == :weak
      assert AnswerConfidence.verdict(env, [knowledge(0.9), knowledge(0.1)]) == :answer
    end
  end
end
