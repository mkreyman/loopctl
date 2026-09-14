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
      assert [%{sha: "deadbeef", error: ":root_commit"}] = report.unreadable
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
