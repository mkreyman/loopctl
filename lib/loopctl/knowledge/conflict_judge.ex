defmodule Loopctl.Knowledge.ConflictJudge do
  @moduledoc """
  Decides what a flagged `potential_conflict` pair actually IS.

  ## The gap this closes

  The novelty gate flags a pair when their cosine similarity clears a mechanical threshold,
  and the nightly lint then judged that pair *on the same number*. Its own evidence string
  said what was wrong with that:

  > similarity cannot distinguish agreement from disagreement, so this pair was never
  > evidence of a conflict

  So every one of the 23,610 verdicts on the hosted instance reads `dismiss / redundant`,
  including any pair that genuinely disagrees — and `contradicts` sat at **0 edges** while
  `Loopctl.Knowledge.find_contradiction_clusters/2` read it, a consumer with no producer
  whose report could only ever be empty.

  A judge that READS the two articles can tell the three cases apart. That is the whole
  feature: same queue, same cap, same drain rate, a verdict that means something.

  ## What a judgement may and may not do

  It may record a verdict and, on `:contradictory`, add a `contradicts` edge. Both are
  ADDITIVE — an edge appears, a row appears, nothing is retired, rewritten or hidden.

  It may **never** produce `supersede` or `merge`. Those defer to the nightly executor, and
  a `:high` supersede is what authorizes an unattended retirement; a judge that both
  classifies a pair and certifies its own verdict as executable is the exact shape
  `Knowledge.annotate_conflict/3` caps agent-role callers to prevent. The disposition stays
  `dismiss` — "this pair needs no destructive action" — and the CLASSIFICATION carries the
  information. Retiring one of a contradicting pair is a judgement about which is right, and
  nothing here is entitled to make it.

  ## Degradation is not optional

  Every error path falls back to the similarity verdict, so a tenant with no LLM key, a
  provider outage or an unparseable reply keeps the drain it has today. The queue must never
  stop being consumed because the judge got better.
  """

  alias Loopctl.Knowledge.ConflictJudge.Similarity

  @typedoc """
  What the pair is.

    * `:redundant` — the same knowledge stated twice. The common case, and what similarity
      alone was already guessing.
    * `:contradictory` — they make incompatible claims. The case that was invisible.
    * `:complementary` — related but neither duplicated nor in conflict; the flag was a
      false positive of the similarity threshold.
  """
  @type classification :: :redundant | :contradictory | :complementary

  @type verdict :: %{
          classification: classification(),
          confidence: :low | :medium | :high,
          rationale: String.t()
        }

  @type article :: %{id: String.t(), title: String.t(), body: String.t()}

  @callback judge(
              scope_or_tenant_id :: term(),
              left :: article(),
              right :: article(),
              opts :: keyword()
            ) :: {:ok, verdict()} | {:error, term()}

  require Logger

  @doc """
  Judge a pair, falling back to the similarity verdict on ANY failure.

  `similarity` is the cosine score the pair was flagged on; it is what the fallback reads,
  and it is also shown to the judge as context rather than as an answer.
  """
  @spec judge(term(), article(), article(), float(), keyword()) :: verdict()
  def judge(scope_or_tenant_id, left, right, similarity, opts \\ []) do
    if enabled?(opts) do
      case impl(opts).judge(scope_or_tenant_id, left, right, [{:similarity, similarity} | opts]) do
        {:ok, verdict} -> verdict
        {:error, reason} -> fallback(similarity, reason)
      end
    else
      Similarity.verdict(similarity)
    end
  rescue
    # A judge is an outbound call behind a behaviour. A raise inside one must degrade the
    # VERDICT, never stop the nightly drain — the queue not being consumed is a worse
    # failure than a pair being classified coarsely.
    error -> fallback(similarity, error)
  end

  @doc "Whether the semantic judge runs (per-call `:conflict_judge` opt over app config)."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get(
      opts,
      :conflict_judge,
      Application.get_env(:loopctl, :knowledge_conflict_judge_enabled, true)
    )
  end

  @doc "The implementation module for this call."
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(
      opts,
      :conflict_judge_impl,
      Application.get_env(:loopctl, :knowledge_conflict_judge, __MODULE__.Llm)
    )
  end

  defp fallback(similarity, reason) do
    Logger.debug("conflict judge fell back to similarity: #{inspect(reason)}")
    Similarity.verdict(similarity)
  end
end
