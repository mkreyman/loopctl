defmodule Loopctl.Knowledge.ConflictJudge.Similarity do
  @moduledoc """
  The pre-existing verdict: everything is `redundant`, graded by cosine similarity.

  Kept as a real module rather than an inline branch because it is BOTH the historical
  behaviour and the fallback every failure path lands on, and those must not drift apart. It
  is what wrote all 23,610 verdicts on the hosted instance.

  Its limitation is not a bug to fix here — it is the reason `ConflictJudge.Llm` exists.
  Similarity says two documents are ABOUT the same thing; it cannot say whether they AGREE.
  """

  @behaviour Loopctl.Knowledge.ConflictJudge

  # At or above this the redundancy is treated as certain; below it the pair was still
  # similar enough to be promoted, just less certainly so. Mirrors the constant the lint
  # worker used before the judge was extracted.
  @high_confidence_similarity 0.95

  @doc "The similarity-only verdict for a cosine score."
  @spec verdict(float() | nil) :: Loopctl.Knowledge.ConflictJudge.verdict()
  def verdict(similarity) do
    sim = similarity || 0.0

    %{
      classification: :redundant,
      confidence: if(sim >= @high_confidence_similarity, do: :high, else: :medium),
      rationale:
        "Auto-judged by cosine similarity #{Float.round(sim / 1, 4)}: high similarity " <>
          "indicates REDUNDANCY (the same knowledge stated twice), not contradiction. " <>
          "Similarity cannot distinguish agreement from disagreement, so this pair was " <>
          "never evidence of a conflict on its own. Both articles are retained; " <>
          "re-annotate this pair to override."
    }
  end

  @impl true
  def judge(_scope_or_tenant_id, _left, _right, opts),
    do: {:ok, verdict(Keyword.get(opts, :similarity))}
end
