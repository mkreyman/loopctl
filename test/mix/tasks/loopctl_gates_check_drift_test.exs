defmodule Mix.Tasks.Loopctl.Gates.CheckDriftTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopctl.Gates.CheckDrift

  # Pure over the report shape. The task's I/O — reading a checkout, exiting non-zero on drift —
  # is exercised by running it; what is asserted here is the redaction, which is the part a
  # public repository cannot get wrong twice.

  @coverage [
    %{kind: :effect, index: 0, pattern: "priv/rates/**", matches: 5},
    %{kind: :effect, index: 1, pattern: "lib/app/gone/**", matches: 0},
    %{kind: :human, index: 0, pattern: "lib/app_web/router.ex", matches: 1}
  ]

  @meta %{repo: "acme/app", trigger_fingerprint: "0123456789ab"}

  describe "report/3 redaction" do
    test "a committed artifact carries no pattern text and no match count" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      assert report.patterns == [
               %{kind: :effect, index: 0, matched: true},
               %{kind: :effect, index: 1, matched: false},
               %{kind: :human, index: 0, matched: true}
             ]

      encoded = Jason.encode!(report)

      refute encoded =~ "priv/rates"
      refute encoded =~ "lib/app/gone"
      refute encoded =~ "lib/app_web/router.ex"
      refute encoded =~ "matches"
    end

    test "the unredacted artifact carries both, for writing outside this repository" do
      report = CheckDrift.report(@coverage, @meta, :full)

      assert report.patterns == @coverage
    end
  end

  describe "report/3 totals" do
    test "counts the patterns, each kind, and the drifted ones" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      assert report.totals == %{
               patterns: 3,
               effect_patterns: 2,
               human_patterns: 1,
               unmatched: 1
             }
    end

    test "the meta is copied through so a later run can say what it checked" do
      assert CheckDrift.report(@coverage, @meta, :redacted).meta == @meta
    end
  end
end
