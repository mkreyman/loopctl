defmodule Loopctl.DeliveryGates.Measurement.ReportTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates.Measurement.GateAReplay
  alias Loopctl.DeliveryGates.Measurement.GateBReplay
  alias Loopctl.DeliveryGates.Measurement.Report
  alias Loopctl.DeliveryGates.Measurement.Ticket

  # No tenant: the report is pure arithmetic over replay results.

  defp result(attrs) do
    struct!(
      %GateBReplay{sha: String.duplicate("a", 40), outcome: :clear},
      Map.merge(
        %{
          diffstat: %{files: 1, changed_lines: 10},
          oracle: %{effect_bearing?: false, families: []},
          committed_at: ~U[2026-09-01 12:00:00Z]
        },
        Enum.into(attrs, %{})
      )
    )
  end

  defp effect_bearing, do: %{effect_bearing?: true, families: [:edi]}

  describe "stratum/1 arithmetic" do
    test "counts clears and false negatives, and rates them over the right denominators" do
      results = [
        result(outcome: :clear, oracle: effect_bearing()),
        result(outcome: :clear, oracle: effect_bearing()),
        result(outcome: :clear),
        result(outcome: :human),
        result(outcome: :size_bound)
      ]

      stratum = Report.stratum(results)

      assert stratum.changes == 5
      assert stratum.cleared == 3
      assert stratum.scored_clears == 3
      assert stratum.false_negatives == 2
      assert stratum.clear_rate == 3 / 5
      assert stratum.false_negative_rate == 2 / 3
    end

    test "the false-negative rate is over SCORED clears, never over all of them" do
      # An unscored clear is neither a false negative nor a true one. In the denominator it
      # would report a rate diluted by changes nobody judged.
      results = [
        result(outcome: :clear, oracle: effect_bearing()),
        result(outcome: :clear, oracle: nil)
      ]

      stratum = Report.stratum(results)

      assert stratum.cleared == 2
      assert stratum.scored_clears == 1
      assert stratum.unscored_clears == 1
      assert stratum.false_negative_rate == 1.0
    end

    test "an empty stratum has NIL rates, not zero ones" do
      stratum = Report.stratum([])

      assert stratum.changes == 0
      assert stratum.clear_rate == nil
      assert stratum.false_negative_rate == nil
      assert stratum.first == nil
    end

    test "a stratum with no clears has a zero clear rate and a nil false-negative rate" do
      stratum = Report.stratum([result(outcome: :human)])

      assert stratum.clear_rate == 0.0
      assert stratum.false_negative_rate == nil
    end

    test "carries the stratum's OWN date range, which is not the run's window" do
      stratum =
        Report.stratum([
          result(committed_at: ~U[2026-08-20 00:00:00Z]),
          result(committed_at: ~U[2026-09-07 00:00:00Z])
        ])

      assert stratum.first == "2026-08-20T00:00:00Z"
      assert stratum.last == "2026-09-07T00:00:00Z"
    end
  end

  describe "gate_b/3" do
    test "the unreadable changes stay in the total and out of every stratum" do
      results = [result(outcome: :clear), GateBReplay.unreadable("deadbeef", :root_commit)]

      report = Report.gate_b(results, %{repo: "acme/claims-app"})

      assert report.totals.changes == 2
      assert report.totals.readable == 1
      assert report.totals.unreadable == 1
      assert report.strata.all.changes == 1
      assert [%{sha: "deadbeef", error_kind: :root_commit}] = report.unreadable
    end

    test "the configuration_applied stratum excludes stale-trigger changes" do
      results = [
        result(outcome: :clear),
        result(outcome: :human, stale_triggers: ["priv/rates/**"])
      ]

      report = Report.gate_b(results, %{})

      assert report.totals.with_stale_triggers == 1
      assert report.strata.all.changes == 2
      assert report.strata.configuration_applied.changes == 1
    end

    test "the production-files stratum is NESTED inside configuration_applied" do
      # Over `readable` its clear rate would carry the stale-trigger artifact the third stratum
      # exists to remove, printed on the line next to the honest one.
      results = [
        result(outcome: :clear, production_files?: true),
        result(outcome: :human, production_files?: true, stale_triggers: ["priv/rates/**"]),
        result(outcome: :clear, production_files?: false)
      ]

      report = Report.gate_b(results, %{})

      assert report.strata.configuration_applied.changes == 2
      assert report.strata.configuration_applied_production_files.changes == 1
      assert report.strata.configuration_applied_production_files.clear_rate == 1.0
      refute Map.has_key?(report.strata, :production_files)
    end

    test "scope_note says :clear is a superset of the auto-merge set" do
      report = Report.gate_b([result(outcome: :clear)], %{})

      assert report.scope_note =~ "SUPERSET"
      assert report.scope_note =~ "MergePrecondition"
    end

    test "reason kinds count RESULTS, so one change with four human paths counts once" do
      results = [
        result(
          outcome: :human,
          reasons: [
            {:human_path, "a.ex", "p"},
            {:human_path, "b.ex", "p"},
            {:max_files_exceeded, 13, 12}
          ]
        )
      ]

      assert %{human_path: 1, max_files_exceeded: 1} = Report.gate_b(results, %{}).reason_kinds
    end
  end

  describe "gate_b/3 redaction" do
    test "a redacted row carries no path, no pattern and no subject" do
      results = [
        result(
          outcome: :clear,
          oracle: effect_bearing(),
          subject: "Stop offering a resubmission (#1411)",
          reasons: [{:human_path, "lib/secret/guarded.ex", "lib/secret/**"}]
        )
      ]

      assert [row] = Report.gate_b(results, %{}).false_negatives

      refute Map.has_key?(row, :subject)
      refute Map.has_key?(row, :reasons)
      refute row |> inspect() |> String.contains?("lib/secret")
    end

    test "a full row carries them, for writing outside the repository" do
      results = [
        result(outcome: :clear, oracle: effect_bearing(), subject: "Stop offering a resubmission")
      ]

      assert [row] = Report.gate_b(results, %{}, detail: :full).false_negatives
      assert row.subject == "Stop offering a resubmission"
    end

    test "the sha is abbreviated in both modes" do
      results = [result(outcome: :clear, oracle: effect_bearing())]

      assert [%{sha: sha}] = Report.gate_b(results, %{}).false_negatives
      assert String.length(sha) == 12
    end

    test "an unreadable row carries the error KIND, not git's stderr" do
      # git names paths and object ids in a read failure: "fatal: bad object <sha>", a gitlink's
      # submodule path, a missing ref's name.
      results = [
        GateBReplay.unreadable("deadbeef", {:git_failed, 128, "fatal: bad object lib/secret.ex"})
      ]

      assert [row] = Report.gate_b(results, %{}).unreadable
      assert row.error_kind == :git_failed
      refute row |> inspect() |> String.contains?("lib/secret")

      assert [full] = Report.gate_b(results, %{}, detail: :full).unreadable
      assert full.error =~ "lib/secret.ex"
    end
  end

  describe "gate_b/3 META redaction" do
    test "absolute local paths never reach a redacted artifact" do
      meta = %{repo: "acme/repo", checkout: "/home/someone/workspace/acme", head: "abc"}

      redacted = Report.gate_b([], meta)

      refute Map.has_key?(redacted.meta, :checkout)
      assert redacted.meta.repo == "acme/repo"

      assert Report.gate_b([], meta, detail: :full).meta.checkout ==
               "/home/someone/workspace/acme"
    end

    test "a trigger-parse error never carries the pattern or the repository into a redacted artifact" do
      # This is a path the task takes BY DESIGN — it replays a configuration failure rather than
      # refusing, because the fail-closed behaviour is a real thing to measure — so an unredacted
      # meta would write a live guard pattern into a public file on an ordinary run.
      error =
        {:error,
         {:invalid_pattern, ["repos", "acme/private-repo", "effect_paths"], "priv/secret/**"}}

      meta = %{repo: "acme/repo", trigger_status: Report.trigger_status(error)}

      redacted = Report.gate_b([], meta)

      assert redacted.meta.trigger_status.status == "error"
      assert redacted.meta.trigger_status.kind == :invalid_pattern
      assert redacted.meta.trigger_status.key_path_depth == 3
      refute Map.has_key?(redacted.meta.trigger_status, :detail)
      refute redacted |> inspect() |> String.contains?("priv/secret")
      refute redacted |> inspect() |> String.contains?("private-repo")

      full = Report.gate_b([], meta, detail: :full)
      assert full.meta.trigger_status.detail =~ "priv/secret/**"
    end

    test "a meta key NOBODY allow-listed does not reach a redacted artifact" do
      # The deny-list version of this published every future key by default, and that defect
      # reappeared the same day through a DEFAULT (`--corpus` falling back to a file path). The
      # allow-list is what makes an unforeseen key safe.
      meta = %{repo: "acme/repo", some_future_key: "/home/someone/secrets/path"}

      redacted = Report.gate_b([], meta)

      refute Map.has_key?(redacted.meta, :some_future_key)
      assert redacted.meta.repo == "acme/repo"
      assert Report.gate_b([], meta, detail: :full).meta.some_future_key =~ "secrets"
    end

    test "every published meta key is one somebody put on the allow-list" do
      meta = Map.new(Report.published_meta_keys(), &{&1, "value"})

      assert Report.gate_b([], meta).meta |> Map.keys() |> Enum.sort() ==
               Enum.sort(Report.published_meta_keys())
    end

    test "the keys that IDENTIFY a run do survive redaction" do
      # The test above builds its input FROM the allow-list, so it moves with any change to it
      # and pins nothing in the still-published direction — a mutation removing a key passed it.
      # These are named literally: an artifact that cannot say which corpus, which head, which
      # trigger document or when is not comparable with anything, which is the whole point of
      # committing it.
      meta = %{
        repo: "acme/repo",
        corpus: "acme/repo issues, all states",
        corpus_fingerprint: "38065cd323ce",
        head: "03ad989c",
        trigger_fingerprint: "9e2db568545c",
        generated_at: "2026-09-14T04:08:37Z",
        since: "2026-03-18",
        until: "2026-09-13",
        tickets: 322,
        unparseable_records: 0,
        harness: "mix loopctl.gates.measure_a"
      }

      published = Report.gate_a([], meta).meta

      for {key, value} <- meta do
        assert Map.get(published, key) == value, "expected meta.#{key} to survive redaction"
      end
    end

    test "a parsed trigger status survives redaction unchanged" do
      meta = %{trigger_status: Report.trigger_status({:ok, :triggers})}

      assert Report.gate_b([], meta).meta.trigger_status == %{status: "parsed"}
    end

    test "the Gate A corpus path and its unparseable reasons are full-detail only" do
      meta = %{
        corpus: "acme/repo",
        tickets_file: "/tmp/someone/tickets.json",
        unparseable_records: 1,
        unparseable_reasons: ["{:missing_number, [\"title\"]}"]
      }

      redacted = Report.gate_a([], meta)

      refute Map.has_key?(redacted.meta, :tickets_file)
      refute Map.has_key?(redacted.meta, :unparseable_reasons)
      assert redacted.meta.unparseable_records == 1

      assert Report.gate_a([], meta, detail: :full).meta.tickets_file ==
               "/tmp/someone/tickets.json"
    end
  end

  describe "gate_a/3" do
    defp replay(attrs), do: attrs |> ticket() |> GateAReplay.replay()

    defp ticket(attrs) do
      {:ok, ticket} = Ticket.parse(build(:measurement_ticket, attrs))
      ticket
    end

    test "splits the intake stratum from the whole corpus" do
      replays = [
        replay(%{"title" => "[Feature] Acme Homecare: a column"}),
        replay(%{}),
        replay(%{"title" => "Refactor the parser", labels: ["enhancement"]})
      ]

      report = Report.gate_a(replays, %{corpus: "acme/repo"})

      assert report.strata.intake.total == 2
      assert report.strata.intake.escalated == 1
      assert report.strata.intake.rate == 0.5
      assert report.strata.all.total == 3
      assert report.strata.all.escalated == 2
    end

    test "counts not_story apart from escalated" do
      replays = [replay(%{"stateReason" => "NOT_PLANNED"})]

      report = Report.gate_a(replays, %{})

      assert report.strata.all.escalated == 0
      assert report.strata.all.not_story == 1
    end

    test "intake_is_feature_share flags a rate that is really the corpus split" do
      replays = [
        replay(%{"title" => "[Feature] Acme Homecare: a column"}),
        replay(%{})
      ]

      share = Report.gate_a(replays, %{}).intake_is_feature_share

      assert share.degenerate?
      assert share.escalated == 1
      assert share.request_shaped == 1
      assert share.escalation_reason_kinds == [:workflow_change]
    end

    test "it is NOT degenerate once another trigger also fires" do
      replays = [
        replay(%{"title" => "[Feature] Acme Homecare: a column"}),
        replay(%{"body" => "We no longer want the date stamp."})
      ]

      share = Report.gate_a(replays, %{}).intake_is_feature_share

      refute share.degenerate?
      assert :inverts_deliberate_behaviour in share.escalation_reason_kinds
    end

    test "no escalations at all is not degenerate" do
      refute Report.gate_a([replay(%{})], %{}).intake_is_feature_share.degenerate?
    end

    test "an absent sensitivity run says so rather than being omitted" do
      report = Report.gate_a([replay(%{})], %{})

      assert report.sensitivity.run == false
    end

    test "a sensitivity run reports the other end of the range" do
      tickets = [ticket(%{"title" => "[Feature] Acme Homecare: a column"})]

      report =
        Report.gate_a(Enum.map(tickets, &GateAReplay.replay/1), %{},
          sensitivity: Enum.map(tickets, &GateAReplay.replay(&1, suppress: [:request_shaped?]))
        )

      assert report.strata.intake.rate == 1.0
      assert report.sensitivity.run == true
      assert report.sensitivity.intake.rate == 0.0
    end
  end

  describe "summarize/1" do
    test "the Gate B summary states every bias, because a rate read without them misleads" do
      summary = Report.summarize(Report.gate_b([result(outcome: :clear)], %{repo: "acme/repo"}))

      assert summary =~ "acme/repo"
      assert summary =~ "UPPER bound"
      assert summary =~ "NOT evidence that Gate B has none"
    end

    test "the Gate A summary states the lower-bound bias and the design's 54%" do
      summary = Report.summarize(Report.gate_a([replay(%{})], %{corpus: "acme/repo"}))

      assert summary =~ "LOWER BOUND"
      assert summary =~ "54%"
    end

    test "an empty stratum prints 'no measurement', never a zero percent" do
      summary = Report.summarize(Report.gate_b([], %{}))

      assert summary =~ "no measurement"
    end
  end
end
