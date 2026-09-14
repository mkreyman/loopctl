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
      refute Map.has_key?(report.meta, :ref)
    end

    test "a meta key NOBODY allow-listed does not reach a redacted artifact" do
      # The point of the allow-list, and the thing the deny-list it replaced could not do: a key
      # added by somebody who never thought about redaction is full-detail only by default.
      meta = Map.put(@meta, :some_future_key, "/home/someone/secrets/path")

      redacted = CheckDrift.report(@coverage, meta, :redacted)

      refute Map.has_key?(redacted.meta, :some_future_key)
      assert CheckDrift.report(@coverage, meta, :full).meta.some_future_key =~ "secrets"
    end

    test "the run is still identifiable without describing the target" do
      # Named LITERALLY, never derived from published_meta_keys/0. A test that builds its
      # expectation from the thing under test moves with any change to it and can never go red
      # when a key is dropped — the self-referential trap #830's own second round hit.
      meta = CheckDrift.report(@coverage, @meta, :redacted).meta

      assert meta.repo == "acme/app"
      assert meta.head == "03ad989c711a433812727fdb4bee8d512857fe5d"
      assert meta.trigger_fingerprint == "0123456789ab"
      assert meta.trigger_checksum_source == "operator_pin"
      assert meta.generated_at == "2026-09-14T03:18:58.260680Z"
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

  describe "one redaction rule, not two" do
    # Two implementations of one redaction rule is the underlying defect behind the leak, and
    # this task still has its own list only because the measurement harness is not on this
    # branch yet (PR #830 is unmerged, so a call to it would not compile). This test is the
    # forcing function: the moment that module IS available, the suite goes red until the
    # duplicate list is deleted and the routing done. A reminder in a comment would not.
    @report_module Module.concat([:Loopctl, :DeliveryGates, :Measurement, :Report])

    test "the local allow-list is deleted as soon as #830's is callable" do
      refute Code.ensure_loaded?(@report_module), """
      #{inspect(@report_module)} is now on this branch, so this task must stop defining its own
      allow-list.

      Do this, in the same commit as the merge that brought it in:

        1. delete @published_meta_keys and published_meta_keys/0 from
           Mix.Tasks.Loopctl.Gates.CheckDrift
        2. defp meta(meta, _redacted), do: Map.take(meta, Report.published_meta_keys())
        3. add :trigger_checksum_source to Report's @meta_published, with the reason: it is a
           property of the RUN rather than of the machine or the target, and it is the only
           field that says whether the fingerprint was verified against the checksum production
           pinned or merely recomputed from a local file
        4. replace this test with one asserting both call sites redact ONE input to the same
           key set, with the keys named literally

      Verified equivalent against #830 at 3d260ca: for this task's meta,
      Map.take(meta, Report.published_meta_keys()) yields the same keys as
      Report.gate_b([], meta, detail: :redacted).meta, plus :trigger_checksum_source once
      step 3 is done.
      """
    end

    test "this task publishes nothing #830's allow-list would not, bar the one added key" do
      # #830's list, transcribed literally at 3d260ca rather than read from the module — the
      # module is not here, and transcribing is what makes this go red if the lists diverge.
      eight_thirty = [
        :corpus,
        :corpus_fingerprint,
        :generated_at,
        :gate,
        :harness,
        :head,
        :limit,
        :repo,
        :since,
        :tickets,
        :trigger_fingerprint,
        :trigger_shape,
        :trigger_status,
        :unparseable_records,
        :until
      ]

      assert CheckDrift.published_meta_keys() -- eight_thirty == [:trigger_checksum_source],
             "this task publishes a key #830's allow-list does not, beyond the one agreed"
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
