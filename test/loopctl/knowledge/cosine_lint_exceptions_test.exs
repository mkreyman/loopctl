defmodule Loopctl.Knowledge.CosineLintExceptionsTest do
  @moduledoc """
  US-27.7b TC-27.7b.3: the NAMED, auditable allowlist of hand-rolled-cosine sites that
  legitimately live OUTSIDE `VectorSearch` (the future US-27.8 "no hand-rolled cosine"
  guard reads this registry so it does not false-positive on these two shapes).

  Asserts the `<=>`-bearing functions (`do_distant_pairs/7` and `novelty_distance_query/4`,
  the function the US-27.7b extraction moved the cosine literal into) AND the logical owner
  `nearest_prior_distance/4` are registered, each with a non-empty rationale, and that the
  registry is the programmatic source of exceptions (`registered?/3` matches exactly the
  documented `{module, function, arity}` triples AND requires a non-empty rationale).
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.CosineLintExceptions

  describe "exceptions/0 — the auditable allowlist (AC-27.7b.3)" do
    test "registers the `<=>`-bearing functions AND the logical owner" do
      registered =
        CosineLintExceptions.exceptions()
        |> Enum.map(&{&1.module, &1.function, &1.arity})

      # do_distant_pairs/7 textually contains its `a.embedding <=> b.embedding`.
      assert {Loopctl.Knowledge, :do_distant_pairs, 7} in registered

      # novelty_distance_query/4 is where the US-27.7b extraction PUT the `MIN(<=>)` literal,
      # so a US-27.8 lint that maps a flagged `<=>` site to its enclosing def lands HERE —
      # it MUST be registered or the lint false-positives.
      assert {Loopctl.Knowledge, :novelty_distance_query, 4} in registered

      # nearest_prior_distance/4 is the logical owner (kept for documentation).
      assert {Loopctl.Knowledge, :nearest_prior_distance, 4} in registered
    end

    test "every exception carries a non-empty one-line rationale" do
      for exc <- CosineLintExceptions.exceptions() do
        assert is_binary(exc.rationale)

        assert String.trim(exc.rationale) != "",
               "exception #{inspect({exc.module, exc.function, exc.arity})} has an empty rationale"
      end
    end

    test "distant_pairs rationale names the column-to-column / no-$const reason" do
      rationale = rationale_for(:do_distant_pairs, 7)
      assert rationale =~ "column-to-column"
      assert rationale =~ ~r/\$const|HNSW/
    end

    test "novelty_distance_query rationale names the MIN-aggregate reason + the bound" do
      rationale = rationale_for(:novelty_distance_query, 4)
      assert rationale =~ "MIN"
      assert rationale =~ ~r/<=>|aggregate|min/
      # Bound is honestly stated as prior-tag selectivity / never full-corpus.
      assert rationale =~ "prior-tag"
      assert rationale =~ "never full-corpus"
    end

    test "nearest_prior_distance rationale marks it the logical owner" do
      rationale = rationale_for(:nearest_prior_distance, 4)
      assert rationale =~ ~r/owner/i
      assert rationale =~ "novelty_distance_query"
    end

    test "the registry is the programmatic source (each entry has a well-formed shape)" do
      for exc <- CosineLintExceptions.exceptions() do
        assert is_atom(exc.module)
        assert is_atom(exc.function)
        assert is_integer(exc.arity) and exc.arity >= 0
      end
    end
  end

  describe "registered?/3 — what the US-27.8 guard calls (AC-27.7b.3)" do
    test "true for every registered exception, including the `<=>`-bearing builder" do
      assert CosineLintExceptions.registered?(Loopctl.Knowledge, :do_distant_pairs, 7)
      assert CosineLintExceptions.registered?(Loopctl.Knowledge, :novelty_distance_query, 4)
      assert CosineLintExceptions.registered?(Loopctl.Knowledge, :nearest_prior_distance, 4)
    end

    test "false for a non-registered function (the guard would still flag it)" do
      refute CosineLintExceptions.registered?(Loopctl.Knowledge, :search_semantic, 3)
      refute CosineLintExceptions.registered?(Loopctl.Knowledge, :do_distant_pairs, 99)
      refute CosineLintExceptions.registered?(SomeOther.Module, :do_distant_pairs, 7)
    end

    test "every registered entry's rationale is non-empty, so registered?/3 actually suppresses" do
      # registered?/3 requires a non-empty rationale; this proves no real entry is suppressed
      # by accident AND documents the contract that a blank rationale would NOT suppress.
      for exc <- CosineLintExceptions.exceptions() do
        assert CosineLintExceptions.registered?(exc.module, exc.function, exc.arity),
               "#{inspect({exc.module, exc.function, exc.arity})} must be recognized by registered?/3"

        assert String.trim(exc.rationale) != ""
      end
    end
  end

  describe "registered_in?/4 — the rationale-rejection branch (AC-27.7b.3)" do
    # @exceptions is all-non-empty by construction, so the rejection branch is unreachable
    # via registered?/3. registered_in?/4 takes the list explicitly, letting us PROVE the
    # gate REJECTS a blank/nil/whitespace rationale (a blank justification must not suppress).
    test "a present, non-blank rationale suppresses (true)" do
      list = [%{module: Foo, function: :bar, arity: 1, rationale: "real reason"}]
      assert CosineLintExceptions.registered_in?(list, Foo, :bar, 1)
    end

    test "an empty-string rationale does NOT suppress (false)" do
      list = [%{module: Foo, function: :bar, arity: 1, rationale: ""}]
      refute CosineLintExceptions.registered_in?(list, Foo, :bar, 1)
    end

    test "a whitespace-only rationale does NOT suppress (false)" do
      list = [%{module: Foo, function: :bar, arity: 1, rationale: "   \t\n"}]
      refute CosineLintExceptions.registered_in?(list, Foo, :bar, 1)
    end

    test "a nil rationale does NOT suppress (false)" do
      list = [%{module: Foo, function: :bar, arity: 1, rationale: nil}]
      refute CosineLintExceptions.registered_in?(list, Foo, :bar, 1)
    end

    test "a non-matching {module, function, arity} does NOT suppress even with a good rationale" do
      list = [%{module: Foo, function: :bar, arity: 1, rationale: "real reason"}]
      refute CosineLintExceptions.registered_in?(list, Foo, :bar, 2)
      refute CosineLintExceptions.registered_in?(list, Foo, :baz, 1)
      refute CosineLintExceptions.registered_in?([], Foo, :bar, 1)
    end
  end

  defp rationale_for(function, arity) do
    CosineLintExceptions.exceptions()
    |> Enum.find(&(&1.function == function and &1.arity == arity))
    |> Map.fetch!(:rationale)
  end
end
