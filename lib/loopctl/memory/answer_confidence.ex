defmodule Loopctl.Memory.AnswerConfidence do
  @moduledoc """
  Whether `/api/v1/recall`'s knowledge results are ANSWERS or the nearest thing to one
  (issue #742).

  Its own module rather than a private function with a test seam. The rule has cases that a
  real recall cannot stage on demand — a field where half the rows scored zero, a row with no
  score at all, a curated winner that diversity dropped — and a rule this load-bearing should
  not be asserted only where it is convenient to arrange. The first version exported an
  `answer_confidence_for_test/2` from the context module to get at them, which put a test
  seam on an API-facing surface; this is the same access without that cost.

  ## What it is about

  THE KNOWLEDGE HALF, and only the rows the caller actually gets. Both halves of that were
  wrong in the first version and the review caught them:

    * it ran over `memory_items ++ knowledge_candidates`, the exact pool
      `meta.results_ranking: "heuristic_cross_source"` exists to warn is NOT calibrated.
      Memory scores are raw cosine with a high floor (~0.3-0.8 for anything at all); a
      keyword-only knowledge row is `raw/(raw+1)` of `ts_rank_cd`, ~0.02-0.2. One
      loosely-related memory at 0.55 against three knowledge rows at 0.05 is a ratio of 11,
      so a response with no answer in it read `:answer` BY CONSTRUCTION — precisely the
      failure this was written to prevent.
    * it ran over the OVER-FETCHED pool (`limit * over_fetch`), so it described rows the
      caller never sees, and it moved with `limit` while the docstring claimed it did not.

  Memory rows are the agent's own prior statements; "is this an answer" is not the same
  question there, and answering it on one number across both scales was the error. So
  `:none` means the KNOWLEDGE half returned nothing, which is what the published schema says,
  and `provenance`, `confidence` and this verdict all describe the same half.
  """

  @answer_separation_default 1.5

  @spec verdict(map(), [map()]) :: :answer | :weak | :none
  def verdict(knowledge_env, merged) do
    rows = Enum.filter(merged, &(Map.get(&1, :source) == :knowledge))

    cond do
      rows == [] -> :none
      curated_answer_present?(knowledge_env, rows) -> :answer
      true -> separation_verdict(rows)
    end
  end

  # `:curated` is `:answer` ONLY IF THE CURATED ARTICLE IS STILL HERE. `hybrid_search/3`
  # pins its winner through diversity selection with `:preselected` precisely so a caller
  # branching on `provenance` can trust the first row; the merged recall does not pin it,
  # and the winner can be dropped as a near-duplicate, excluded by the recall history cache,
  # or re-sorted and cut by the merged `limit`. Publishing "a governed article answers this"
  # while that article is absent from the response is a worse lie than a weak verdict.
  defp curated_answer_present?(%{meta: meta}, rows) do
    Map.get(meta, :provenance) == :curated and
      case Map.get(meta, :curated_article_id) do
        nil -> false
        id -> Enum.any?(rows, &(row_article_id(&1) == id))
      end
  end

  defp curated_answer_present?(_knowledge_env, _rows), do: false

  # A merged knowledge row WRAPS its article rather than carrying its id, so the identity
  # the resolver named is one level in.
  defp row_article_id(%{article: %{id: id}}), do: id
  defp row_article_id(%{article: %{"id" => id}}), do: id
  defp row_article_id(_row), do: nil

  # SEPARATION, over scored rows only. An UNSCORED row is excluded rather than counted as a
  # zero: unmeasurable is not irrelevant, the same distinction the diversity selector draws
  # when it refuses to drop a vector-less candidate as a duplicate. Counting them as zero
  # dragged the median down and turned a flat field into an "answer".
  defp separation_verdict(rows) do
    scores =
      rows
      |> Enum.map(&candidate_score/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(:desc)

    case scores do
      # Nothing measurable. Not an answer, and not "no results" either — the rows are there.
      [] -> :weak
      # Nothing to be separated FROM. Calling this `:answer` would make the verdict depend
      # on how many rows the caller asked for rather than on the corpus.
      [_only] -> :weak
      [top | rest] -> separation(top, median(rest))
    end
  end

  # A ZERO MEDIAN IS NOT AN EMPTY FIELD, and reading it as one was the worst of the review's
  # findings: half the field scoring zero is a DEGRADED pool, and during an embedding outage
  # both halves degrade together — so the single most degraded response the endpoint can
  # produce shipped the strongest possible verdict. A field that scored nothing supports no
  # claim about the row above it.
  defp separation(top, median) when is_number(top) and is_number(median) and median > 0 do
    if top / median >= answer_separation(), do: :answer, else: :weak
  end

  defp separation(_top, _median), do: :weak

  # Configurable, for the reason this whole function exists: the argument against a fixed
  # relevance floor is that it goes stale when fusion, the embedding model or the corpus
  # moves, and a ratio is still a constant — just on a steadier axis. Every sibling
  # threshold here is config-driven; making this one need a deploy would be the same trap
  # one level along.
  defp answer_separation,
    do: Application.get_env(:loopctl, :recall_answer_separation, @answer_separation_default)

  defp median([]), do: 0.0

  defp median(scores) do
    sorted = Enum.sort(scores)
    count = length(sorted)
    mid = div(count, 2)

    case rem(count, 2) do
      1 -> Enum.at(sorted, mid)
      0 -> (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  # `nil`, never `0.0`: an unscored row is excluded from the field rather than counted as
  # the bottom of it.
  defp candidate_score(%{score: score}) when is_number(score), do: score
  defp candidate_score(%{"score" => score}) when is_number(score), do: score
  defp candidate_score(_candidate), do: nil
end
