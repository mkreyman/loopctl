defmodule Loopctl.DeliveryGates.TriggerHoleClassesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The three pattern-hole CLASSES the first Gate B measurement found (loopctl #828, PR #830),
  each as a change that cleared under a pattern set declaring the intent and escalates once the
  pattern covers what that intent plainly covers.

  Every path here is SYNTHETIC. The real ones name a private repository and reconstruct the
  guard map design §13 keeps out of this public repository; they are in the run's knowledge-wiki
  article and the unredacted artifact. What is reproduced here is the SHAPE, which is what
  generalises: the classes are properties of the glob semantics, not of one repository.
  """

  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.DeliveryGates.Triggers

  @repo "acme/claims-app"

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp triggers(effect_paths, human_paths) do
    config = %{
      "version" => 1,
      "repos" => %{
        @repo => %{
          "effect_paths" => effect_paths,
          "human_paths" => human_paths,
          "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
        }
      }
    }

    binary = Jason.encode!(config)
    Triggers.parse(binary, sha256(binary))
  end

  # A file list that satisfies every pattern in BOTH sets, so no stale trigger fires and the
  # only thing separating the two runs is whether the pattern covers the changed file.
  @repo_files [
    "lib/app/claims.ex",
    "lib/app/claims/batch.ex",
    "lib/app/payroll.ex",
    "lib/app/payroll/fee_schedule/parser.ex",
    "lib/app_web/router.ex",
    "config/config.exs",
    "config/runtime.exs"
  ]

  defp evaluate(triggers, file) do
    GateB.evaluate(
      :merge,
      %{
        repo: @repo,
        files: [file],
        renames: [],
        repo_files: @repo_files,
        diffstat: %{files: 1, changed_lines: 10}
      },
      triggers
    )
  end

  describe "class 1: a directory pattern does not match its sibling FILE" do
    @before ["lib/app/claims/**", "config/runtime.exs"]
    @after_ ["lib/app/claims/**", "lib/app/claims.ex", "config/runtime.exs"]
    @human ["lib/app_web/router.ex"]

    test "the context module beside a guarded directory clears" do
      result = evaluate(triggers(@before, @human), "lib/app/claims.ex")

      assert result.outcome == :clear
      assert result.reasons == []
      assert result.effect_matches == []
    end

    test "the sibling file pattern makes it prove its effect" do
      result = evaluate(triggers(@after_, @human), "lib/app/claims.ex")

      assert result.outcome == :prove_effect
      assert {"lib/app/claims.ex", "lib/app/claims.ex"} in result.effect_matches
    end

    test "the directory the pattern already named is unaffected" do
      for set <- [@before, @after_] do
        assert evaluate(triggers(set, @human), "lib/app/claims/batch.ex").outcome == :prove_effect
      end
    end
  end

  describe "class 2: a file pattern does not match its sibling DIRECTORY" do
    @before ["lib/app/payroll.ex", "config/runtime.exs"]
    @after_ ["lib/app/payroll.ex", "lib/app/payroll/**", "config/runtime.exs"]
    @human ["lib/app_web/router.ex"]

    test "the subtree that grew beside a guarded module clears" do
      result = evaluate(triggers(@before, @human), "lib/app/payroll/fee_schedule/parser.ex")

      assert result.outcome == :clear
      assert result.effect_matches == []
    end

    test "the sibling directory pattern makes it prove its effect" do
      result = evaluate(triggers(@after_, @human), "lib/app/payroll/fee_schedule/parser.ex")

      assert result.outcome == :prove_effect

      assert {"lib/app/payroll/fee_schedule/parser.ex", "lib/app/payroll/**"} in result.effect_matches
    end

    test "the module the pattern already named is unaffected" do
      for set <- [@before, @after_] do
        assert evaluate(triggers(set, @human), "lib/app/payroll.ex").outcome == :prove_effect
      end
    end
  end

  describe "class 3: a config pattern names one config file" do
    @before ["config/runtime.exs", "lib/app/claims/**"]
    @after_ ["config/config.exs", "config/runtime.exs", "lib/app/claims/**"]
    @human ["lib/app_web/router.ex"]

    test "the other config file clears" do
      result = evaluate(triggers(@before, @human), "config/config.exs")

      assert result.outcome == :clear
      assert result.effect_matches == []
    end

    test "naming it makes it prove its effect" do
      result = evaluate(triggers(@after_, @human), "config/config.exs")

      assert result.outcome == :prove_effect
      assert {"config/config.exs", "config/config.exs"} in result.effect_matches
    end
  end

  describe "closing a hole can only ADD coverage" do
    test "no path cleared by the wider set is escalated by the narrower one" do
      narrow = ["lib/app/claims/**", "config/runtime.exs"]

      wide = [
        "lib/app/claims/**",
        "lib/app/claims.ex",
        "lib/app/payroll.ex",
        "lib/app/payroll/**",
        "config/config.exs",
        "config/runtime.exs"
      ]

      human = ["lib/app_web/router.ex"]

      for file <- @repo_files ++ ["mix.exs", "test/app/claims_test.exs"] do
        narrow_outcome = evaluate(triggers(narrow, human), file).outcome
        wide_outcome = evaluate(triggers(wide, human), file).outcome

        # `:clear` is the only permissive outcome. Widening may turn a clear into a
        # prove_effect; it may never turn a prove_effect or a human into a clear.
        if narrow_outcome != :clear do
          assert wide_outcome != :clear,
                 "#{file}: widening the pattern set cleared a change the narrower set did not"
        end
      end
    end
  end
end
