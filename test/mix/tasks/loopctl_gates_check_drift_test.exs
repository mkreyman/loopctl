defmodule Mix.Tasks.Loopctl.Gates.CheckDriftTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.Triggers
  alias Mix.Tasks.Loopctl.Gates.CheckDrift

  # Pure over the report shape and the checksum resolution. The task's I/O — reading a checkout,
  # exiting non-zero on drift — is exercised by running it; what is asserted here is the
  # redaction and the operator's checksum pin, which are the two things a public repository
  # cannot get wrong twice.

  @coverage [
    %{kind: :effect, index: 0, pattern: "priv/rates/**", matches: 5},
    %{kind: :effect, index: 1, pattern: "lib/app/gone/**", matches: 0},
    %{kind: :human, index: 0, pattern: "lib/app_web/router.ex", matches: 1}
  ]

  # The meta the TASK actually builds, key for key. A trimmed stub is why the first redaction
  # test could not see the leak it was written to catch: there was no `checkout` in it to drop.
  @meta %{
    repo: "acme/app",
    checkout: "/home/someone/workspace/acme-app",
    ref: "HEAD",
    head: "03ad989c711a433812727fdb4bee8d512857fe5d",
    tree_files: 3982,
    trigger_fingerprint: "0123456789ab",
    trigger_checksum_source: "operator_pin",
    generated_at: "2026-09-14T03:18:58.260680Z",
    harness: "mix loopctl.gates.check_drift"
  }

  describe "report/3 redaction" do
    test "a committed artifact carries no pattern text and no match count" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      assert report.patterns == [
               %{kind: :effect, index: 0, matched: true},
               %{kind: :effect, index: 1, matched: false},
               %{kind: :human, index: 0, matched: true}
             ]
    end

    test "a committed artifact carries no local checkout path and no target tree size" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      refute Map.has_key?(report.meta, :checkout)
      refute Map.has_key?(report.meta, :tree_files)
    end

    test "the run is still identifiable without describing the target" do
      meta = CheckDrift.report(@coverage, @meta, :redacted).meta

      assert meta.repo == "acme/app"
      assert meta.head == "03ad989c711a433812727fdb4bee8d512857fe5d"
      assert meta.ref == "HEAD"
      assert meta.trigger_fingerprint == "0123456789ab"
      assert meta.trigger_checksum_source == "operator_pin"
      assert meta.harness == "mix loopctl.gates.check_drift"
    end

    test "nothing anywhere in the encoded artifact names a path, a pattern or a machine" do
      encoded = @coverage |> CheckDrift.report(@meta, :redacted) |> Jason.encode!()

      for needle <- ["/home/", "/Users/", ".ex", "**", "3982"] do
        refute String.contains?(encoded, needle),
               "the redacted artifact contains #{inspect(needle)}"
      end
    end

    test "the unredacted artifact carries all of it, for writing outside this repository" do
      report = CheckDrift.report(@coverage, @meta, :full)

      assert report.patterns == @coverage
      assert report.meta == @meta
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
  end

  describe "checksum/2 — the operator's pin" do
    @document ~s({"version":1})
    @document_hash :sha256 |> :crypto.hash(~s({"version":1})) |> Base.encode16(case: :lower)

    test "with no pin, the document's own bytes are hashed" do
      assert CheckDrift.checksum(@document, nil) == @document_hash
    end

    test "a pin is returned VERBATIM, so a mismatch reaches Triggers.parse and is refused" do
      pinned = String.duplicate("a", 64)

      assert CheckDrift.checksum(@document, pinned) == pinned

      # The failure this exists to prevent: replacing a mismatched pin with the hash of
      # whatever is on disk verifies the document against itself and can never fail.
      refute CheckDrift.checksum(@document, pinned) == @document_hash

      assert Triggers.parse(
               @document,
               CheckDrift.checksum(@document, pinned)
             ) == {:error, :checksum_mismatch}
    end

    test "a matching pin verifies, which is what makes the trailing-newline trap catchable" do
      assert CheckDrift.checksum(@document, @document_hash) == @document_hash

      # The same JSON WITH a trailing newline is a different document under the same pin.
      assert Triggers.parse(
               @document <> "\n",
               CheckDrift.checksum(@document <> "\n", @document_hash)
             ) == {:error, :checksum_mismatch}
    end

    test "a pin is case-insensitive, as Triggers.parse/2 accepts it" do
      assert CheckDrift.checksum(@document, String.upcase(@document_hash)) == @document_hash
    end
  end
end
