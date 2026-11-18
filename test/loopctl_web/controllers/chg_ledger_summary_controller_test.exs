defmodule LoopctlWeb.ChgLedgerSummaryControllerTest do
  @moduledoc """
  US-50.6 (TC-50.6.1, TC-50.6.2): `GET /api/v1/chg_ledger/summary` answers what the /chg
  dashboard shows, computed by `Loopctl.Changes.Dashboard`, for any key from agent role up,
  scoped to the key's tenant, and refuses a period over the cap. Seeds on `AdminRepo` and
  reads through `Loopctl.HeavyRead` (on `AdminRepo` in test), so it runs async.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Dashboard
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.LedgerRow
  alias LoopctlWeb.ChgLedgerSummaryController

  setup :verify_on_exit!

  setup do
    {_secret, source} = fixture(:intake_source, %{})
    {agent_key, _} = fixture(:api_key, %{tenant_id: source.tenant_id, role: :agent})
    %{source: source, agent_key: agent_key}
  end

  defp row!(source, attrs) do
    repo = Events.repo_key(source.repo_full_name)

    AdminRepo.insert!(%LedgerRow{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: repo,
      host: attrs.host,
      kind: attrs.kind,
      sha: attrs[:sha],
      verdict: attrs[:verdict],
      ms: attrs[:ms],
      at: Map.get(attrs, :at, DateTime.add(DateTime.utc_now(), -3600)),
      raw: Map.merge(%{"v" => 1, "repo" => repo, "kind" => attrs.kind}, attrs[:raw] || %{}),
      row_hash: Ecto.UUID.generate()
    })
  end

  defp seed!(source) do
    s1 = String.duplicate("1", 40)

    row!(source, %{
      kind: "chg",
      host: "minis",
      sha: s1,
      verdict: "pass",
      ms: 900,
      raw: %{"mode" => "all", "selection" => "mix.lock changed", "tests_ms" => 800}
    })

    row!(source, %{
      kind: "chg",
      host: "x1",
      verdict: "fail",
      ms: 500,
      raw: %{"mode" => "affected"}
    })

    row!(source, %{kind: "gate", host: "minis", sha: s1, verdict: "fail", ms: 1000})
    row!(source, %{kind: "runner", host: "x1", ms: 42, raw: %{"load" => "0.5"}})

    # Outside a narrowed window: ten days back.
    row!(source, %{
      kind: "gate",
      host: "minis",
      verdict: "pass",
      ms: 10,
      at: DateTime.add(DateTime.utc_now(), -10, :day)
    })
  end

  defp summary(raw_key, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get(~p"/api/v1/chg_ledger/summary", params)
  end

  describe "TC-50.6.1: summary matches the dashboard source" do
    test "an agent key reads the same aggregates Dashboard computes", ctx do
      seed!(ctx.source)
      repo = ctx.source.repo_full_name

      body = ctx.agent_key |> summary(%{repo: repo}) |> json_response(200)
      data = body["data"]

      {:ok, filters} = ChgLedgerSummaryController.filters(%{"repo" => repo}, DateTime.utc_now())

      expected =
        ctx.source.tenant_id |> Dashboard.summary(filters) |> ChgLedgerSummaryController.wire()

      # Through JSON, so atom keys and DateTimes compare as the wire carries them.
      expected = expected |> Jason.encode!() |> Jason.decode!()

      for panel <- ~w(gate_outcomes fallbacks selection phase_times flaky runner_samples
                      review_outcomes attention) do
        assert data[panel] == expected[panel], "#{panel} differs from Dashboard's"
      end

      assert %{"fallbacks" => 1, "checks" => 2} = data["fallbacks"]
      assert data["filters"]["repo"] == repo
      assert {:ok, _, _} = DateTime.from_iso8601(data["filters"]["since"])
    end

    test "host and since narrow it", ctx do
      seed!(ctx.source)

      gate_days = fn data -> Enum.filter(data["gate_outcomes"], &(&1["kind"] == "gate")) end

      # The default period is 7 days, so the ten-day-old gate row is outside it.
      recent = ctx.agent_key |> summary(%{}) |> json_response(200)
      assert length(gate_days.(recent["data"])) == 1

      since = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601()
      wide = ctx.agent_key |> summary(%{since: since}) |> json_response(200)
      assert length(gate_days.(wide["data"])) == 2

      x1 = ctx.agent_key |> summary(%{host: "x1"}) |> json_response(200)
      assert [%{"host" => "x1"}] = x1["data"]["runner_samples"]
      assert Enum.all?(x1["data"]["gate_outcomes"], &(&1["kind"] == "chg"))
    end

    test "tenant isolation: another tenant's key sees none of it", ctx do
      seed!(ctx.source)
      other = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :agent})

      data = other_key |> summary(%{}) |> json_response(200) |> Map.fetch!("data")
      assert data["gate_outcomes"] == []
      assert data["runner_samples"] == []
      assert data["attention"] == []
    end

    test "no key is a 401", _ctx do
      assert build_conn() |> get(~p"/api/v1/chg_ledger/summary") |> json_response(401)
    end
  end

  describe "TC-50.6.2: period cap" do
    test "a 120-day period is a 422 naming the cap", ctx do
      since = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.to_iso8601()
      body = ctx.agent_key |> summary(%{since: since}) |> json_response(422)

      assert body["error"]["message"] =~ "#{Dashboard.max_period_days()} days"
    end

    test "exactly the cap passes; one second over is refused" do
      until = ~U[2026-11-18 12:00:00Z]
      at_cap = DateTime.add(until, -Dashboard.max_period_days(), :day)
      params = %{"until" => DateTime.to_iso8601(until)}

      assert {:ok, _} =
               ChgLedgerSummaryController.filters(
                 Map.put(params, "since", DateTime.to_iso8601(at_cap)),
                 until
               )

      assert {:error, :unprocessable_entity, _} =
               ChgLedgerSummaryController.filters(
                 Map.put(params, "since", DateTime.to_iso8601(DateTime.add(at_cap, -1))),
                 until
               )
    end

    test "a malformed timestamp or an inverted period is a 422", ctx do
      assert ctx.agent_key |> summary(%{since: "yesterday"}) |> json_response(422)

      now = DateTime.utc_now()

      inverted = %{
        since: DateTime.to_iso8601(now),
        until: now |> DateTime.add(-1, :day) |> DateTime.to_iso8601()
      }

      assert ctx.agent_key |> summary(inverted) |> json_response(422)
    end
  end
end
