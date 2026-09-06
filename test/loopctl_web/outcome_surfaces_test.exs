defmodule LoopctlWeb.OutcomeSurfacesTest do
  @moduledoc """
  The retrieval VIEWS that carry `meta.outcome` render it.

  The unit tests in `LoopctlWeb.OutcomeTest` prove the classification; these prove it
  is actually WIRED on each view listed below, which is the failure a shared helper
  invites — a view is changed later and quietly stops rendering the key.

  The table is HAND-MAINTAINED, so it cannot catch a NEW surface that ships without the
  key; the guarantee it gives is over the VIEW-rendered surfaces the docs name
  (`mcp-server/README.md`), and the catalog endpoints that carry no `outcome` are absent
  on purpose. `corpus_search` is the one documented retrieval surface missing here for a
  reason that is not an omission: it renders `outcome` in `LoopctlWeb.CorpusController`
  rather than a view module, so its wiring is proved at the HTTP boundary instead —
  `test/loopctl_web/controllers/corpus_controller_test.exs`, "meta.outcome separates a
  real hit from a corpus that genuinely holds nothing".
  """
  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.KnowledgeContextJSON
  alias LoopctlWeb.KnowledgeHybridSearchJSON
  alias LoopctlWeb.KnowledgeProgressiveJSON
  alias LoopctlWeb.KnowledgeSearchJSON
  alias LoopctlWeb.MemoryJSON
  alias LoopctlWeb.Outcome
  alias LoopctlWeb.RecallJSON

  setup :verify_on_exit!

  # One entry per rendered surface: a label, and a zero-arity function returning the
  # rendered `%{data: _, meta: _}`. Table-driven so adding a surface is one row and
  # FORGETTING one is a visible gap rather than a silent pass.
  defp surfaces do
    [
      {"knowledge search",
       fn ->
         KnowledgeSearchJSON.search(
           %{results: [], meta: %{total_count: 0, limit: 10, offset: 0}},
           "combined"
         )
       end},
      {"knowledge list (keyset)",
       fn ->
         KnowledgeSearchJSON.keyset(%{
           results: [],
           next_cursor: nil,
           has_more: false,
           limit: 10,
           include_body: false,
           byte_truncated: false
         })
       end},
      {"knowledge context",
       fn ->
         KnowledgeContextJSON.context(%{
           results: [],
           meta: %{total_count: 0, limit: 10, recency_weight: 0.0}
         })
       end},
      {"knowledge hybrid search",
       fn ->
         KnowledgeHybridSearchJSON.hybrid_search(%{
           results: [],
           meta: %{provenance: :retrieved, confidence: 0.0, limit: 10, offset: 0}
         })
       end},
      {"progressive index",
       fn ->
         KnowledgeProgressiveJSON.index(%{
           stubs: [],
           meta: %{top_k: 10, candidate_count: 0, truncated: false}
         })
       end},
      {"heat index",
       fn ->
         KnowledgeProgressiveJSON.heat_index(%{
           results: [],
           meta: %{
             top_k: 10,
             returned: 0,
             unresolved: 0,
             truncated: false,
             char_budget: 8000,
             chars: 2,
             heat_window: "2026-09-01T00:00:00Z",
             counted_access_types: ["get"],
             drill: "knowledge_progressive_drill"
           }
         })
       end},
      {"article index (knowledge list)", fn -> ArticleJSON.index(%{articles: [], meta: %{}}) end},
      {"memory recall",
       fn ->
         MemoryJSON.recall(%{
           results: [],
           meta: %{total_count: 0, fallback: false, reason: nil, underfilled: false}
         })
       end},
      {"merged recall", fn -> RecallJSON.context(recall_envelope()) end}
    ]
  end

  defp recall_envelope do
    %{
      results: [],
      memory: %{
        results: [],
        meta: %{total_count: 0, fallback: false, reason: nil, underfilled: false}
      },
      knowledge: %{results: [], meta: %{total_count: 0, limit: 10, offset: 0}},
      meta: %{
        query: "anything",
        project_id: nil,
        total_count: 0,
        memory_count: 0,
        knowledge_count: 0,
        degraded?: false,
        degraded_reason: nil,
        search_mode: nil,
        results_ranking: "heuristic_cross_source"
      }
    }
  end

  test "every retrieval and list view renders meta.outcome from the shared vocabulary" do
    for {label, render} <- surfaces() do
      %{meta: meta} = render.()

      assert Map.has_key?(meta, :outcome), "#{label} renders no meta.outcome"

      assert meta.outcome in Outcome.values(),
             "#{label} rendered an outcome outside the published vocabulary: #{inspect(meta.outcome)}"

      assert meta.outcome == "empty",
             "#{label} classified a healthy zero-result render as #{meta.outcome}"
    end
  end

  test "a degraded half is classified as such on every surface that can disclose one" do
    fallback = %{
      total_count: 0,
      limit: 10,
      offset: 0,
      fallback: true,
      fallback_reason: "embedding_timeout"
    }

    assert KnowledgeSearchJSON.search(%{results: [], meta: fallback}, "combined").meta.outcome ==
             "fallback"

    assert KnowledgeContextJSON.context(%{
             results: [],
             meta: %{
               total_count: 0,
               limit: 10,
               recency_weight: 0.0,
               fallback: true,
               fallback_reason: "embedding_timeout"
             }
           }).meta.outcome == "fallback"

    assert KnowledgeHybridSearchJSON.hybrid_search(%{
             results: [],
             meta: %{
               provenance: :retrieved,
               confidence: 0.0,
               limit: 10,
               offset: 0,
               fallback: true,
               fallback_reason: "embedding_timeout"
             }
           }).meta.outcome == "fallback"

    # The memory shed: `fallback: true` with a capacity reason and no substitute lane.
    assert MemoryJSON.recall(%{
             results: [],
             meta: %{
               total_count: 0,
               fallback: true,
               reason: "heavy_read_overloaded",
               underfilled: true
             }
           }).meta.outcome == "degraded"
  end

  test "the merged recall classifies a hard knowledge error as error, not as a miss" do
    envelope = recall_envelope()

    meta =
      envelope.meta
      |> Map.put(:degraded?, true)
      |> Map.put(:degraded_reason, "invalid_weights")

    assert RecallJSON.context(%{envelope | meta: meta}).meta.outcome == "error"
  end

  test "the merged recall reports its own outcome and the memory half reports the memory half's" do
    envelope = recall_envelope()

    rendered =
      RecallJSON.context(%{
        envelope
        | memory: %{
            results: [],
            meta: %{
              total_count: 0,
              fallback: true,
              reason: "heavy_read_overloaded",
              underfilled: true
            }
          },
          meta:
            envelope.meta
            |> Map.put(:degraded?, true)
            |> Map.put(:degraded_reason, "heavy_read_overloaded")
      })

    assert rendered.meta.outcome == "degraded"
    assert rendered.memory.meta.outcome == "degraded"
  end

  test "the merged recall keeps a shed that served keyword-only a fallback" do
    # The knowledge half sheds under the SAME tag and answers keyword-only, whose remedy
    # is the opposite one. The rendered meta republishes the lane the reported half
    # served, so the two are still distinguishable after the merge.
    envelope = recall_envelope()

    rendered =
      RecallJSON.context(%{
        envelope
        | meta:
            envelope.meta
            |> Map.put(:degraded?, true)
            |> Map.put(:degraded_reason, "heavy_read_overloaded")
            |> Map.put(:search_mode, "keyword_only")
      })

    assert rendered.meta.search_mode == "keyword_only"
    assert rendered.meta.outcome == "fallback"
  end
end
