defmodule Loopctl.Workers.LegacyEmbeddingRetirementWorkerTest do
  @moduledoc """
  GH #551 — the daily driver for the legacy-column retirement trigger.

  The load-bearing test here is `probe error`: an unreadable catalog must surface as a
  failed job and must NOT enqueue anything, because "I could not check" rendering as
  "nothing to do" is the exact defect the issue describes. It is reachable only through
  the injected `Loopctl.Embeddings.LegacyRetirementBehaviour` — the test database always
  answers that query successfully.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.LegacyRetirement
  alias Loopctl.Embeddings.RetirementObservation
  alias Loopctl.Workers.LegacyEmbeddingRetirementWorker
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  setup :verify_on_exit!

  defp probe(overrides \\ %{}) do
    Map.merge(
      %{
        side_table_reads: 1,
        legacy_columns: ["articles", "memories"],
        legacy_index_scans: %{"articles_embedding_hnsw_idx" => 674},
        stats_reset_at: nil
      },
      overrides
    )
  end

  defp verdict(overrides) do
    Map.merge(
      %{
        verdict: :not_due,
        trigger: nil,
        reasons: ["only 0 of 30 day(s) observed"],
        legacy_columns: ["articles", "memories"],
        clear_days: 0,
        required_clear_days: 30,
        review_by: ~D[2027-01-22],
        deadline_passed?: false,
        legacy_index_scans: %{"articles_embedding_hnsw_idx" => 674}
      },
      overrides
    )
  end

  # `config/test.exs` runs Oban `testing: :inline`, which EXECUTES an inserted job
  # instead of storing it — so an enqueue assertion needs `:manual` for the duration of
  # the call, exactly as the sibling `ChannelPostRescanWorker` tests do.
  defp run_job do
    Oban.Testing.with_testing_mode(:manual, fn ->
      LegacyEmbeddingRetirementWorker.perform(%Oban.Job{args: %{}})
    end)
  end

  describe "a healthy run" do
    test "records today's observation from the live probe" do
      assert :ok = run_job()

      observation = AdminRepo.get_by(RetirementObservation, observed_on: Date.utc_today())

      assert observation
      assert "articles" in observation.legacy_columns_present
      refute observation.legacy_index_scans == %{}
    end

    test "a :not_due verdict enqueues no operator alert" do
      stub(Loopctl.MockLegacyRetirement, :probe, fn -> {:ok, probe()} end)
      stub(Loopctl.MockLegacyRetirement, :evaluate, fn _probe, _opts -> verdict(%{}) end)

      assert :ok = run_job()
      refute_enqueued(worker: ScaleAlertDeliveryWorker)
    end

    test "a :retired verdict enqueues nothing and stays quiet" do
      stub(Loopctl.MockLegacyRetirement, :probe, fn ->
        {:ok, probe(%{legacy_columns: []})}
      end)

      stub(Loopctl.MockLegacyRetirement, :evaluate, fn _probe, _opts ->
        verdict(%{verdict: :retired, legacy_columns: []})
      end)

      log =
        capture_log(fn ->
          assert :ok = run_job()
        end)

      refute_enqueued(worker: ScaleAlertDeliveryWorker)
      refute log =~ "RETIREMENT DUE"
    end
  end

  describe "a :due verdict" do
    setup do
      stub(Loopctl.MockLegacyRetirement, :probe, fn -> {:ok, probe()} end)

      stub(Loopctl.MockLegacyRetirement, :evaluate, fn _probe, _opts ->
        verdict(%{
          verdict: :due,
          trigger: :evidence,
          reasons: ["30 consecutive clear day(s) at or above the 30-day bar"],
          clear_days: 30
        })
      end)

      :ok
    end

    test "logs at :error, so the condition surfaces with no alert channel configured" do
      # Scale alerting is OFF in prod (#539) until a receiver exists, so the log is the
      # channel that actually works today. A signal that only exists on an unconfigured
      # webhook is the same silence the issue is about.
      log =
        capture_log(fn ->
          assert :ok = run_job()
        end)

      assert log =~ "RETIREMENT DUE"
      assert log =~ "evidence"
      assert log =~ "articles"
    end

    test "enqueues an operator alert carrying the trigger and the deadline" do
      capture_log(fn ->
        assert :ok = run_job()
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert [job] = all_enqueued(worker: ScaleAlertDeliveryWorker)
      payload = job.args["payload"]

      assert payload["alert"] == "embeddings.legacy_retirement_due"
      assert payload["metric"] == "embeddings.legacy_retirement.clear_days"
      assert payload["value"] == 30
      assert payload["threshold"] == 30
      assert payload["trigger"] == "evidence"
      assert payload["legacy_columns"] == ["articles", "memories"]
      assert payload["review_by"] == "2027-01-22"
      assert payload["legacy_index_scans"] == %{"articles_embedding_hnsw_idx" => 674}
    end
  end

  describe "fail closed" do
    test "a probe error returns {:error, _} and enqueues NOTHING" do
      error = %Postgrex.Error{message: "permission denied for view pg_stat_user_indexes"}

      stub(Loopctl.MockLegacyRetirement, :probe, fn -> {:error, error} end)

      # `evaluate/2` must never be consulted: there is no reading to evaluate, and a
      # verdict derived from an absent probe is worse than no verdict.
      stub(Loopctl.MockLegacyRetirement, :evaluate, fn _probe, _opts ->
        flunk("evaluate/2 must not run when the probe failed")
      end)

      log =
        capture_log(fn ->
          assert {:error, ^error} = run_job()
        end)

      refute_enqueued(worker: ScaleAlertDeliveryWorker)
      assert log =~ "could not read the legacy embedding footprint"

      # The wording matters as much as the branch: an operator reading this line must
      # not take it for a clean bill of health.
      assert log =~ "NOT evidence that the columns are gone"
    end

    test "a probe error emits the probe-failed telemetry with a BOUNDED error class" do
      event = Loopctl.TelemetryEvents.legacy_retirement_probe_failed()
      handler = "test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        event,
        fn _e, measurements, metadata, _ ->
          send(parent, {:probe_failed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      stub(Loopctl.MockLegacyRetirement, :probe, fn ->
        {:error, %Postgrex.Error{message: "a message that must never become a tag"}}
      end)

      capture_log(fn -> run_job() end)

      assert_received {:probe_failed, %{count: 1}, metadata}
      assert metadata.error_class == "Postgrex.Error"
      refute metadata.error_class =~ "must never become a tag"
    end

    test "a failed observation write does not suppress a :due verdict" do
      # A storage hiccup costs one day of evidence. Letting it also swallow a verdict we
      # just successfully measured would trade a small loss for the total one.
      stub(Loopctl.MockLegacyRetirement, :probe, fn -> {:ok, probe()} end)

      stub(Loopctl.MockLegacyRetirement, :record, fn _probe, _opts ->
        {:error, %{errors: [observed_on: {"boom", []}]}}
      end)

      stub(Loopctl.MockLegacyRetirement, :evaluate, fn _probe, _opts ->
        verdict(%{verdict: :due, trigger: :deadline, deadline_passed?: true})
      end)

      capture_log(fn ->
        assert :ok = run_job()
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)
    end
  end

  describe "the real trigger, end to end" do
    test "a clear window recorded day by day ends in a :due verdict" do
      today = Date.utc_today()
      required = LegacyRetirement.required_clear_days()
      scans = %{"articles_embedding_hnsw_idx" => 674}

      for offset <- (required - 1)..0//-1 do
        {:ok, _} =
          LegacyRetirement.record(
            probe(%{legacy_index_scans: scans}),
            today: Date.add(today, -offset)
          )
      end

      assert %{verdict: :due, trigger: :evidence} =
               LegacyRetirement.evaluate(probe(%{legacy_index_scans: scans}), today: today)
    end
  end
end
