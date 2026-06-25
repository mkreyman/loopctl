defmodule Loopctl.Knowledge.CosineLintExceptionsTest do
  @moduledoc """
  US-27.7b TC-27.7b.3: the NAMED, auditable allowlist of hand-rolled-cosine sites that
  legitimately live OUTSIDE `VectorSearch` (the future US-27.8 "no hand-rolled cosine"
  guard reads this registry so it does not false-positive on these two shapes).

  Asserts BOTH `do_distant_pairs` and `nearest_prior_distance` are registered, each with a
  non-empty rationale, and that the registry is the programmatic source of exceptions
  (`registered?/3` matches exactly the documented `{module, function, arity}` triples).
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.CosineLintExceptions

  describe "exceptions/0 — the auditable allowlist (AC-27.7b.3)" do
    test "registers BOTH distant_pairs and nearest_prior_distance" do
      registered =
        CosineLintExceptions.exceptions()
        |> Enum.map(&{&1.module, &1.function, &1.arity})

      assert {Loopctl.Knowledge, :do_distant_pairs, 7} in registered
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

    test "nearest_prior_distance rationale names the MIN-aggregate reason" do
      rationale = rationale_for(:nearest_prior_distance, 4)
      assert rationale =~ "MIN"
      assert rationale =~ ~r/aggregate|min/
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
    test "true for both registered exceptions" do
      assert CosineLintExceptions.registered?(Loopctl.Knowledge, :do_distant_pairs, 7)
      assert CosineLintExceptions.registered?(Loopctl.Knowledge, :nearest_prior_distance, 4)
    end

    test "false for a non-registered function (the guard would still flag it)" do
      refute CosineLintExceptions.registered?(Loopctl.Knowledge, :search_semantic, 3)
      refute CosineLintExceptions.registered?(Loopctl.Knowledge, :do_distant_pairs, 99)
      refute CosineLintExceptions.registered?(SomeOther.Module, :do_distant_pairs, 7)
    end
  end

  defp rationale_for(function, arity) do
    CosineLintExceptions.exceptions()
    |> Enum.find(&(&1.function == function and &1.arity == arity))
    |> Map.fetch!(:rationale)
  end
end
