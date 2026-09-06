defmodule LoopctlWeb.OutcomeSurfacesTest do
  @moduledoc """
  The retrieval VIEWS that carry `meta.outcome` render it.

  The unit tests in `LoopctlWeb.OutcomeTest` prove the classification; these prove it
  is actually WIRED on each view listed below, which is the failure a shared helper
  invites — a view is changed later and quietly stops rendering the key.

  The table is HAND-MAINTAINED, so it cannot catch a NEW surface that ships without the
  key; the guarantee it gives is over the VIEW-rendered surfaces the docs name
  (`mcp-server/README.md`). The catalog endpoints are IN the table now: they were once
  excluded because they disclose no degradation of their own, which is true of the value
  and irrelevant to the key — a client reads an absent `outcome` as "no classification
  available" and cannot tell a deliberate opt-out from an old server.

  The surfaces that render `outcome` in a CONTROLLER rather than a view module are proved
  at the HTTP boundary instead, in their own controller tests: `corpus_search` and the
  corpus list (`corpus_controller_test.exs`), the suggested-links read
  (`knowledge_suggest_links_controller_test.exs`), and drafts/conflicts
  (`article_workflow_controller_test.exs`).
  """
  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.KnowledgeContextJSON
  alias LoopctlWeb.KnowledgeHybridSearchJSON
  alias LoopctlWeb.KnowledgeIndexJSON
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
      {"knowledge index (offset)",
       fn ->
         KnowledgeIndexJSON.index(
           %{
             articles: %{},
             meta: %{
               total_count: 0,
               categories: %{},
               offset: 0,
               limit: 1000,
               truncated: false
             }
           },
           ["id", "title", "category"]
         )
       end},
      {"knowledge index (keyset)",
       fn ->
         KnowledgeIndexJSON.keyset(
           %{results: [], next_cursor: nil, has_more: false, limit: 1000},
           ["id", "title", "category"]
         )
       end},
      {"memory list",
       fn -> MemoryJSON.index(%{results: [], meta: %{total_count: 0, limit: 20, offset: 0}}) end},
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

  test "a catalog page holding rows is success, counted across category groups" do
    # The table above renders every surface EMPTY, so on its own it cannot tell
    # `Outcome.put(meta, count)` from `Outcome.put(meta, 0)` — both classify `"empty"`,
    # and a wiring that always passed zero would pass it. This is the other half: a page
    # that HOLDS rows must classify `"success"`.
    #
    # What this does NOT bind, said plainly: the knowledge index counts rows across
    # category groups rather than counting the groups, and `outcome` reads only zero vs
    # non-zero, so no assertion here can separate the two.
    article = fn title, category ->
      %{id: Ecto.UUID.generate(), title: title, category: category, tags: [], status: :published}
    end

    rendered =
      KnowledgeIndexJSON.index(
        %{
          articles: %{
            "pattern" => [article.("One", :pattern), article.("Two", :pattern)],
            "finding" => [article.("Three", :finding), article.("Four", :finding)]
          },
          meta: %{
            total_count: 4,
            categories: %{"pattern" => 2, "finding" => 2},
            offset: 0,
            limit: 1000,
            truncated: false
          }
        },
        ["id", "title", "category"]
      )

    assert rendered.meta.outcome == "success"

    keyset =
      KnowledgeIndexJSON.keyset(
        %{
          results: [
            %{
              id: Ecto.UUID.generate(),
              title: "One",
              category: :pattern,
              tags: [],
              status: :published
            }
          ],
          next_cursor: nil,
          has_more: false,
          limit: 1000
        },
        ["id", "title", "category"]
      )

    assert keyset.meta.outcome == "success"

    tenant = fixture(:tenant)

    memory =
      MemoryJSON.index(%{
        results: [fixture(:memory, %{tenant_id: tenant.id})],
        meta: %{total_count: 1, limit: 20, offset: 0}
      })

    assert memory.meta.outcome == "success"
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
