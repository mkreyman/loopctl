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
      meta = %{degraded: true, degraded_reason: "heavy_read_overloaded", total_count: 2}
      assert Outcome.derive(meta, 2) == "degraded"
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
end
