defmodule LoopctlWeb.OutcomeTest do
  @moduledoc """
  Unit tests for the ONE derivation of `meta.outcome`.

  Every case here is written against the meta shape a PRODUCER actually emits, not
  against an invented one — the memory shed envelope, the memory ILIKE fallback, the
  degraded knowledge half of `/recall`, and the corpus lane disclosures. A rule that
  only holds for a hand-made map is a rule that will not fire in production.
  """
  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.Outcome

  setup :verify_on_exit!

  describe "values/0 and schema/0" do
    test "publishes exactly the five documented outcomes" do
      assert Outcome.values() == ~w(success empty degraded fallback error)
    end

    test "the OpenAPI enum is the SAME list derive/2 can return" do
      schema = Outcome.schema()

      assert schema.type == :string
      assert schema.enum == Outcome.values()
      assert is_binary(schema.description) and schema.description != ""
    end
  end

  describe "a rendered outcome is a documented one" do
    # The doc-hygiene rule in CLAUDE.md: a changed API constraint goes in the endpoint's
    # `operation/2` spec, not only in the controller. Nothing flags a render that ships
    # with no matching schema entry, and the failure is silent for exactly the audience
    # that cannot read this source tree — so it is bound here instead of remembered.
    #
    # Rendering happens in a `*_json.ex` view or in the controller itself; documenting
    # happens in the controller's `operation/2` or in a shared `Loopctl.ApiSpec.Schemas`
    # module it names. So the unit is the SURFACE, and the check is: every module that
    # renders has a documenter, resolved by name.
    #
    # The bound this does NOT give, stated so nobody reads more into a green: it is
    # per-MODULE, not per-ACTION. A view rendering two actions is satisfied by one of them
    # being documented, and the mapping is hand-written, so a renderer added with no entry
    # fails loudly (the `unmapped` assertion) while a SECOND action on a mapped module
    # does not. What it does catch is the whole silent class — a render shipped with no
    # OpenAPI meta property anywhere.
    @renderers_to_documenters %{
      "article_json.ex" => ["article_controller.ex"],
      "knowledge_context_json.ex" => ["knowledge_context_controller.ex"],
      "knowledge_hybrid_search_json.ex" => ["knowledge_hybrid_search_controller.ex"],
      "knowledge_index_json.ex" => ["knowledge_index_controller.ex"],
      "knowledge_progressive_json.ex" => ["knowledge_progressive_controller.ex"],
      "knowledge_search_json.ex" => ["knowledge_search_controller.ex"],
      "memory_json.ex" => ["memory_controller.ex", "../../loopctl/api_spec/schemas.ex"],
      "recall_json.ex" => ["memory_controller.ex", "../../loopctl/api_spec/schemas.ex"],
      "article_workflow_controller.ex" => ["article_workflow_controller.ex"],
      "corpus_controller.ex" => ["corpus_controller.ex"],
      "knowledge_suggest_links_controller.ex" => ["knowledge_suggest_links_controller.ex"]
    }

    @controllers_dir "lib/loopctl_web/controllers"

    # The PER-ACTION half of the guard, which the per-module scan below cannot give: it
    # reads the BUILT OpenAPI document and looks at the exact 200 `meta` object a client
    # would generate a type from. Each entry is one endpoint that renders `meta.outcome`,
    # so a schema shared by two actions no longer satisfies both by satisfying one.
    @documented_endpoints [
      {"/api/v1/knowledge/search", :get},
      {"/api/v1/knowledge/context", :get},
      {"/api/v1/knowledge/hybrid_search", :post},
      {"/api/v1/knowledge/progressive_index", :get},
      {"/api/v1/knowledge/heat_index", :get},
      {"/api/v1/knowledge/index", :get},
      {"/api/v1/articles", :get},
      {"/api/v1/knowledge/drafts", :get},
      {"/api/v1/knowledge/conflicts", :get},
      {"/api/v1/knowledge/articles/{id}/suggested_links", :get},
      {"/api/v1/memory", :get},
      {"/api/v1/memory/recall", :post},
      {"/api/v1/recall", :post},
      {"/api/v1/corpora", :get},
      {"/api/v1/corpora/{id}/search", :post}
    ]

    test "each endpoint that renders meta.outcome documents it in its own 200 meta object" do
      spec = Loopctl.ApiSpec.spec()

      for {path, verb} <- @documented_endpoints do
        item = spec.paths[path]
        assert item, "no such path in the spec: #{path} (renamed? then rename it here too)"

        operation = Map.get(item, verb)
        assert operation, "#{verb} #{path} is not in the spec"

        meta = meta_schema(spec, operation)

        assert meta, "#{verb} #{path} documents no 200 meta object"

        assert Map.has_key?(meta.properties || %{}, :outcome),
               "#{verb} #{path} renders meta.outcome but does not document it"

        assert meta.properties.outcome.enum == Outcome.values(),
               "#{verb} #{path} documents an outcome enum that is not the published one"
      end
    end

    test "every module that renders meta.outcome has a mapped documenter that declares it" do
      rendering =
        @controllers_dir
        |> Path.join("*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(&1 |> File.read!() |> String.contains?("Outcome.put")))
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      assert rendering != [], "the scan matched no renderers — the guard would be vacuous"

      unmapped = rendering -- Map.keys(@renderers_to_documenters)

      assert unmapped == [],
             "these modules render meta.outcome with no documenter mapped: " <>
               "#{inspect(unmapped)}. Add the OpenAPI meta property, then map it here."

      for renderer <- rendering do
        documenters = @renderers_to_documenters[renderer]

        assert Enum.any?(documenters, fn documenter ->
                 @controllers_dir
                 |> Path.join(documenter)
                 |> File.read!()
                 |> String.contains?("Outcome.schema()")
               end),
               "#{renderer} renders meta.outcome but none of #{inspect(documenters)} " <>
                 "documents it"
      end
    end
  end

  describe "derive/2 — the healthy pair" do
    test "rows and no degradation is success" do
      assert Outcome.derive(%{total_count: 3, limit: 10, offset: 0}, 3) == "success"
    end

    test "no rows and no degradation is empty" do
      assert Outcome.derive(%{total_count: 0, limit: 10, offset: 0}, 0) == "empty"
    end

    test "a meta disclosing nothing at all still classifies" do
      assert Outcome.derive(%{}, 0) == "empty"
      assert Outcome.derive(%{}, 1) == "success"
    end

    test "a page walked PAST THE END is success, never empty - exhaustion is not absence" do
      # `count` is the PAGE. On the offset-paginated surfaces an empty page over a
      # non-empty set said "the row is genuinely absent" to an agent doing an existence
      # check, while `total_count` in the same meta said it is not.
      assert Outcome.derive(%{total_count: 42, limit: 10, offset: 90}, 0) == "success"

      assert Outcome.derive(%{total_count: 5, limit: 20, offset: 100, include_body: false}, 0) ==
               "success"

      # Offset zero is a real miss and stays one.
      assert Outcome.derive(%{total_count: 0, limit: 10, offset: 0}, 0) == "empty"
    end

    test "an offset over a set that matched NOTHING is still a real miss" do
      # The mirror of the case above, and the way over-correcting it reads: a stale
      # cursor or a re-narrowed filter carries `offset > 0` over a set of zero. No
      # earlier page carried rows, so "success" would tell an existence check the
      # opposite of the truth. `total_count == 0` bounds the matched set on every
      # surface - a pool of zero holds no matches either.
      assert Outcome.derive(%{total_count: 0, limit: 10, offset: 10}, 0) == "empty"
      assert Outcome.derive(%{total_count: 0, limit: 20, offset: 20}, 0) == "empty"

      # An ABSENT total_count (the hybrid meta only maybe_puts it) stays exhaustion.
      assert Outcome.derive(%{limit: 10, offset: 10}, 0) == "success"
    end

    test "an exhausted page never masks a degradation" do
      meta = %{
        total_count: 42,
        limit: 10,
        offset: 90,
        fallback: true,
        fallback_reason: "embedding_timeout"
      }

      assert Outcome.derive(meta, 0) == "fallback"
    end
  end

  describe "derive/2 — fallback" do
    test "the knowledge/memory fallback flag" do
      meta = %{total_count: 0, fallback: true, fallback_reason: "embedding_timeout"}
      assert Outcome.derive(meta, 0) == "fallback"
    end

    test "the memory ILIKE envelope Loopctl.Memory emits when embedding is unavailable" do
      meta = %{total_count: 0, fallback: true, reason: "no_embedding_key", underfilled: true}
      assert Outcome.derive(meta, 0) == "fallback"
    end

    test "the US-41.4 degraded label" do
      assert Outcome.derive(%{degraded: true, fallback_reason: "egress_blocked"}, 0) == "fallback"
    end

    test "the merged-recall internal spelling, so an unprojected envelope classifies alike" do
      assert Outcome.derive(%{degraded?: true, fallback_reason: "embedding_crash"}, 0) ==
               "fallback"
    end

    test "the corpus tier's name for the same event" do
      meta = %{
        lanes: ["keyword"],
        search_mode: "keyword_only",
        semantic_unavailable_reason: "no_embedding_key"
      }

      assert Outcome.derive(meta, 4) == "fallback"
    end

    test "a fallback that still returned rows is a fallback, not a success" do
      assert Outcome.derive(%{fallback: true, fallback_reason: "embedding_timeout"}, 9) ==
               "fallback"
    end
  end

  describe "derive/2 — degraded" do
    test "the memory shed envelope is degraded even though it sets fallback: true" do
      # `Loopctl.Memory.overloaded_memory_env/2` verbatim. This is the ONE deviation
      # from the documented precedence, and the reason it exists: nothing was served in
      # the semantic lane's place, so the remedy is to WAIT, not to retry a different
      # ranking.
      meta = %{
        total_count: 0,
        fallback: true,
        reason: "heavy_read_overloaded",
        underfilled: true
      }

      assert Outcome.derive(meta, 0) == "degraded"
    end

    test "a shed reported through the merged /recall degraded_reason" do
      # The merged meta republishes the reported half's lane, so the two sheds that share
      # this tag stay distinguishable here exactly as they are on /knowledge/search: a
      # half that served nothing is `search_mode: nil` and needs a WAIT.
      meta = %{
        degraded: true,
        degraded_reason: "heavy_read_overloaded",
        search_mode: nil,
        total_count: 2
      }

      assert Outcome.derive(meta, 2) == "degraded"
      assert Outcome.derive(%{meta | search_mode: "keyword_only"}, 2) == "fallback"
    end

    test "a corpus semantic lane that ran but could not reach the whole corpus" do
      meta = %{
        lanes: ["keyword", "semantic"],
        search_mode: "combined",
        semantic_under_filled: true
      }

      assert Outcome.derive(meta, 5) == "degraded"
    end

    test "a vector read that ran without pgvector's iterative scan" do
      meta = %{total_count: 1, ann_iterative_scan: "unavailable"}
      assert Outcome.derive(meta, 1) == "degraded"
    end

    test "an applied or off iterative scan is NOT a degradation" do
      assert Outcome.derive(%{ann_iterative_scan: "applied"}, 1) == "success"
      assert Outcome.derive(%{ann_iterative_scan: "off"}, 0) == "empty"
    end

    test "a corpus keyword lane that dropped out" do
      meta = %{lanes: ["semantic"], keyword_unavailable_reason: "heavy_read_overloaded"}
      assert Outcome.derive(meta, 3) == "degraded"
    end

    test "a KNOWLEDGE shed that DID serve keyword-only is a fallback, not a shed" do
      # The precedence deviation is bounded by "served no substitute lane". The knowledge
      # tier sheds the semantic lane under the SAME tag and answers with keyword-only, and
      # that response needs the fallback remedy - retry the same query, never reword,
      # because the keyword lane ANDs its terms. Classifying it degraded cost it exactly
      # that sentence.
      meta = %{
        fallback: true,
        fallback_reason: "heavy_read_overloaded",
        search_mode: "keyword_only"
      }

      assert Outcome.derive(meta, 3) == "fallback"
      assert Outcome.derive(meta, 0) == "fallback"
    end
  end

  describe "derive/2 — error" do
    test "every tag in the degraded-knowledge contract classifies as error" do
      for tag <- Loopctl.Memory.knowledge_degraded_reason_tags() do
        assert Outcome.derive(%{total_count: 0, degraded?: true, fallback_reason: tag}, 0) ==
                 "error"

        assert Outcome.derive(%{degraded: true, degraded_reason: tag}, 0) == "error"
      end
    end

    test "the contract is non-empty, so the loop above is never vacuous" do
      refute Loopctl.Memory.knowledge_degraded_reason_tags() == []
    end

    test "the memory envelope that could not run at all is an error, not a fallback" do
      # `Loopctl.Memory.unavailable_memory_env/3` verbatim: zero rows, `fallback: true`,
      # and NO substitute lane. Read as a fallback it told the agent to retry the same
      # query forever against a persistent configuration fault only an operator clears.
      for tag <- Loopctl.Memory.memory_unavailable_reason_tags() do
        meta = %{total_count: 0, fallback: true, reason: tag, underfilled: true}
        assert Outcome.derive(meta, 0) == "error"

        assert Outcome.derive(%{degraded: true, degraded_reason: tag}, 0) == "error"
      end
    end

    test "the memory unavailable set is non-empty, so the loop above is never vacuous" do
      refute Loopctl.Memory.memory_unavailable_reason_tags() == []
    end

    test "a request-error tag beside REAL ROWS is a partial read, not a dead request" do
      # On the merged /recall the tag names ONE half. "error" tells the caller the empty
      # envelope says nothing about the corpus - said over seven memory rows the other
      # half returned, it makes the agent discard them and ask again.
      meta = %{degraded: true, degraded_reason: "bad_request", total_count: 7, memory_count: 7}

      assert Outcome.derive(meta, 7) == "degraded"
      assert Outcome.derive(%{meta | total_count: 0, memory_count: 0}, 0) == "error"
    end

    test "an error tag arriving on a LANE key is not a request error" do
      # The corpus and memory lanes draw from an embedding/capacity vocabulary that does
      # not overlap the request-error contract. Only the two contract-bearing keys are
      # read, so a future collision cannot reclassify a served half as a request that
      # never ran.
      meta = %{semantic_unavailable_reason: "bad_request"}
      assert Outcome.derive(meta, 2) == "fallback"
    end
  end

  describe "derive/2 — precedence" do
    test "error outranks fallback" do
      meta = %{fallback: true, degraded?: true, fallback_reason: "invalid_weights"}
      assert Outcome.derive(meta, 0) == "error"
    end

    test "a capacity shed outranks the fallback flag it travels with" do
      assert Outcome.derive(%{fallback: true, reason: "heavy_read_overloaded"}, 0) == "degraded"
    end

    test "fallback outranks a short lane" do
      meta = %{
        fallback: true,
        fallback_reason: "embedding_timeout",
        ann_iterative_scan: "unavailable"
      }

      assert Outcome.derive(meta, 0) == "fallback"
    end

    test "every degradation outranks empty, so a broken empty never reads as a real miss" do
      for meta <- [
            %{fallback: true, fallback_reason: "embedding_timeout"},
            %{reason: "heavy_read_overloaded"},
            %{semantic_under_filled: true},
            %{degraded_reason: "bad_request"}
          ] do
        refute Outcome.derive(meta, 0) == "empty"
      end
    end
  end

  describe "put/2 and put_for/2" do
    test "put/2 adds the key and changes nothing else" do
      meta = %{total_count: 2, limit: 10, offset: 0}
      result = Outcome.put(meta, 2)

      assert result.outcome == "success"
      assert Map.delete(result, :outcome) == meta
    end

    test "put_for/2 counts the list it is given" do
      assert Outcome.put_for(%{}, []).outcome == "empty"
      assert Outcome.put_for(%{}, [:a, :b]).outcome == "success"
    end

    test "put/2 classifies from the meta it is writing into" do
      assert Outcome.put(%{fallback: true, fallback_reason: "embedding_timeout"}, 0).outcome ==
               "fallback"
    end
  end

  # Resolves the 200 response's `meta` property, following a component `$ref` — a shared
  # response schema (MemoryListResponse, MemoryRecallResponse) reaches the document as a
  # reference, and reading `.properties` off one silently returns nil.
  #
  # The component key is looked up as the STRING the `$ref` already carries. An earlier
  # draft went through `String.to_existing_atom/1` and passed or raised depending on
  # whether the schema module happened to be loaded yet — a guard that is green by load
  # order is worse than no guard.
  defp meta_schema(spec, operation) do
    schema =
      operation.responses[200].content["application/json"].schema
      |> resolve_ref(spec)

    case schema.properties[:meta] do
      nil -> nil
      meta -> resolve_ref(meta, spec)
    end
  end

  defp resolve_ref(%OpenApiSpex.Reference{"$ref": ref}, spec) do
    name = ref |> String.split("/") |> List.last()

    Map.get(spec.components.schemas, name)
  end

  defp resolve_ref(schema, _spec), do: schema
end
