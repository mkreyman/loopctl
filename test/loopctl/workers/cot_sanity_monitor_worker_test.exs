defmodule Loopctl.Workers.CotSanityMonitorWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Loopctl.Fixtures

  alias Loopctl.Workers.CotSanityMonitorWorker

  # 24h scan window — reports are inserted "now" so they land inside it.
  defp cutoff, do: DateTime.add(DateTime.utc_now(), -86_400, :second)

  describe "perform/1" do
    test "runs and returns :ok" do
      assert :ok = CotSanityMonitorWorker.perform(%Oban.Job{})
    end
  end

  describe "score_recent_completions/1 (worker-02: Decimal estimated_hours)" do
    test "estimated_hours reaches LazyScore as a float, not a Decimal" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id, estimated_hours: Decimal.new("8")})

      _report =
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          input_tokens: 1_000,
          output_tokens: 500,
          tool_call_count: 100,
          cot_length_tokens: 5_000,
          tests_run_count: 25
        })

      # The sandbox transaction only sees this test's single report.
      [entry] = CotSanityMonitorWorker.score_recent_completions(cutoff())

      # The schemaless select casts NUMERIC -> float8, so Postgrex hands back a
      # plain float rather than a %Decimal{}.
      assert is_float(entry.report.estimated_hours)
      assert entry.report.estimated_hours == 8.0
    end

    test "token-ratio factor engages for a story with a non-null estimated_hours" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id, estimated_hours: Decimal.new("8")})

      # total_tokens = 1500, expected = 8h * 10k = 80k, ratio ~1.9% < 20%.
      # The other three factors are deliberately non-suspicious (nil), so the
      # score equals the token-ratio weight exactly. Pre-fix, the Decimal
      # estimated_hours disabled this factor and the score collapsed to 0.0.
      _report =
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          input_tokens: 1_000,
          output_tokens: 500,
          tool_call_count: 100,
          cot_length_tokens: 5_000,
          tests_run_count: 25
        })

      [entry] = CotSanityMonitorWorker.score_recent_completions(cutoff())

      assert entry.score == 0.8
      assert entry.flagged
      assert Enum.any?(entry.reasons, &String.contains?(&1, "Token usage is"))
    end

    test "small-story exemption engages for a story estimated at <= 1 hour" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id, estimated_hours: Decimal.new("0.5")})

      # Every raw factor is suspicious (0 tool calls, tiny CoT, 0 tests), but a
      # sub-1-hour story is exempt: floor 0.0, no reasons, not flagged. Pre-fix
      # the Decimal skipped the exemption and this scored ~0.87 (flagged).
      _report =
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          input_tokens: 500,
          output_tokens: 500,
          tool_call_count: 0,
          cot_length_tokens: 10,
          tests_run_count: 0
        })

      [entry] = CotSanityMonitorWorker.score_recent_completions(cutoff())

      assert entry.score == 0.0
      assert entry.reasons == []
      refute entry.flagged
    end
  end
end
