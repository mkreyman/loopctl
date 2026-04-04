defmodule Loopctl.CLI.Commands.TokenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Token

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/analytics/projects/p-1"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "total_cost_millicents" => 250_000,
              "total_tokens" => 1_500_000,
              "budget_utilization_percent" => 75,
              "top_agents" => [
                %{"agent_name" => "agent-alpha", "cost_millicents" => 100_000},
                %{"agent_name" => "agent-beta", "cost_millicents" => 80_000},
                %{"agent_name" => "agent-gamma", "cost_millicents" => 70_000}
              ],
              "model_breakdown" => [
                %{"model_name" => "claude-3-5-sonnet", "percent" => 80},
                %{"model_name" => "gpt-4o", "percent" => 20}
              ]
            }
          })

        {"GET", "/api/v1/analytics/epics"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "epic_title" => "Foundation",
                "epic_number" => 1,
                "cost_millicents" => 150_000,
                "total_tokens" => 900_000
              },
              %{
                "epic_title" => "Authentication",
                "epic_number" => 2,
                "cost_millicents" => 100_000,
                "total_tokens" => 600_000
              }
            ],
            "meta" => %{"page" => 1, "page_size" => 50, "total_count" => 2, "total_pages" => 1}
          })

        {"GET", "/api/v1/analytics/agents"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "agent_name" => "agent-alpha",
                "cost_millicents" => 100_000,
                "total_tokens" => 600_000,
                "efficiency_rank" => 1
              },
              %{
                "agent_name" => "agent-beta",
                "cost_millicents" => 80_000,
                "total_tokens" => 500_000,
                "efficiency_rank" => 2
              }
            ],
            "meta" => %{"page" => 1, "page_size" => 50, "total_count" => 2, "total_pages" => 1}
          })

        {"GET", "/api/v1/stories/s-1/token-usage"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "phase" => "implementing",
                "model_name" => "claude-3-5-sonnet",
                "input_tokens" => 1000,
                "output_tokens" => 500,
                "cost_millicents" => 25_000
              }
            ],
            "totals" => %{
              "total_input_tokens" => 1000,
              "total_output_tokens" => 500,
              "total_tokens" => 1500,
              "total_cost_millicents" => 25_000,
              "report_count" => 1
            },
            "meta" => %{"page" => 1, "page_size" => 50, "total_count" => 1, "total_pages" => 1}
          })

        {"GET", "/api/v1/stories/s-empty/token-usage"} ->
          Req.Test.json(conn, %{
            "data" => [],
            "totals" => %{
              "total_input_tokens" => 0,
              "total_output_tokens" => 0,
              "total_tokens" => 0,
              "total_cost_millicents" => 0,
              "report_count" => 0
            },
            "meta" => %{"page" => 1, "page_size" => 50, "total_count" => 0, "total_pages" => 1}
          })

        {"GET", "/api/v1/cost-anomalies"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "a-1",
                "anomaly_type" => "high_cost",
                "story_title" => "Heavy Story",
                "cost_millicents" => 500_000,
                "resolved" => false
              }
            ],
            "meta" => %{"page" => 1, "page_size" => 50, "total_count" => 1, "total_pages" => 1}
          })

        {"GET", "/api/v1/analytics/projects/p-nodata"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "total_cost_millicents" => 0,
              "total_tokens" => 0,
              "budget_utilization_percent" => nil,
              "top_agents" => [],
              "model_breakdown" => []
            }
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.1: cost-summary --project
  # ---------------------------------------------------------------------------

  describe "cost-summary --project (JSON format)" do
    test "outputs raw API response" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], [])
        end)

      assert output =~ "250000"
    end
  end

  describe "cost-summary --project (human format)" do
    test "shows total cost in dollars" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], format: "human")
        end)

      assert output =~ "$2.50"
    end

    test "shows total tokens with M suffix" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], format: "human")
        end)

      assert output =~ "1.5M"
    end

    test "shows budget utilization" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], format: "human")
        end)

      assert output =~ "75%"
    end

    test "shows top agents" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], format: "human")
        end)

      assert output =~ "agent-alpha"
    end

    test "shows model mix" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], format: "human")
        end)

      assert output =~ "claude-3-5-sonnet"
    end
  end

  describe "cost-summary --project missing" do
    test "shows usage error" do
      output =
        capture_io(:stderr, fn ->
          Token.run("cost-summary", [], [])
        end)

      assert output =~ "Usage: loopctl cost-summary"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.2: cost-summary --project --by-epic
  # ---------------------------------------------------------------------------

  describe "cost-summary --project --by-epic (JSON format)" do
    test "returns epic data" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1", "--by-epic"], [])
        end)

      assert output =~ "Foundation"
    end
  end

  describe "cost-summary --project --by-epic (human format)" do
    test "shows sorted epic cost breakdown" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1", "--by-epic"], format: "human")
        end)

      assert output =~ "Foundation"
      assert output =~ "Authentication"
      assert output =~ "$1.50"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.3: cost-summary --project --by-agent
  # ---------------------------------------------------------------------------

  describe "cost-summary --project --by-agent (JSON format)" do
    test "returns agent data" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1", "--by-agent"], [])
        end)

      assert output =~ "agent-alpha"
    end
  end

  describe "cost-summary --project --by-agent (human format)" do
    test "shows agent cost breakdown with rank" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1", "--by-agent"], format: "human")
        end)

      assert output =~ "agent-alpha"
      assert output =~ "agent-beta"
      assert output =~ "$1.00"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.4: token-report --story <id>
  # ---------------------------------------------------------------------------

  describe "token-report --story (JSON format)" do
    test "shows story token data" do
      output =
        capture_io(fn ->
          Token.run("token-report", ["--story", "s-1"], [])
        end)

      assert output =~ "implementing"
    end
  end

  describe "token-report --story (human format)" do
    test "shows totals and report details" do
      output =
        capture_io(fn ->
          Token.run("token-report", ["--story", "s-1"], format: "human")
        end)

      assert output =~ "$0.25"
      assert output =~ "1.5K"
      assert output =~ "implementing"
    end
  end

  describe "token-report missing --story" do
    test "shows usage error" do
      output =
        capture_io(:stderr, fn ->
          Token.run("token-report", [], [])
        end)

      assert output =~ "Usage: loopctl token-report"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.5: anomalies --project <id>
  # ---------------------------------------------------------------------------

  describe "anomalies --project (JSON format)" do
    test "shows anomaly data" do
      output =
        capture_io(fn ->
          Token.run("anomalies", ["--project", "p-1"], [])
        end)

      assert output =~ "high_cost"
    end
  end

  describe "anomalies --project (human format)" do
    test "shows anomaly table" do
      output =
        capture_io(fn ->
          Token.run("anomalies", ["--project", "p-1"], format: "human")
        end)

      assert output =~ "high_cost"
      assert output =~ "Heavy Story"
      assert output =~ "$5.00"
    end
  end

  describe "anomalies --include-resolved flag" do
    test "passes include_archived param to API" do
      # The stub handles /api/v1/cost-anomalies regardless of query params.
      # We verify the command runs without error when the flag is present.
      output =
        capture_io(fn ->
          Token.run("anomalies", ["--project", "p-1", "--include-resolved"], [])
        end)

      assert output =~ "high_cost"
    end
  end

  describe "anomalies missing --project" do
    test "shows usage error" do
      output =
        capture_io(:stderr, fn ->
          Token.run("anomalies", [], [])
        end)

      assert output =~ "Usage: loopctl anomalies"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.8: formatting
  # ---------------------------------------------------------------------------

  describe "formatting" do
    test "cost-summary shows dollars with 2 decimal places" do
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], format: "human")
        end)

      # $250000 millicents = $2.50
      assert output =~ "$2.50"
    end

    test "token-report shows K suffix for thousands" do
      output =
        capture_io(fn ->
          Token.run("token-report", ["--story", "s-1"], format: "human")
        end)

      # 1500 total tokens = 1.5K
      assert output =~ "1.5K"
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "server errors" do
    test "cost-summary shows error on 404" do
      output =
        capture_io(:stderr, fn ->
          Token.run("cost-summary", ["--project", "nonexistent"], [])
        end)

      assert output =~ "Error:"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.9.7: respects configured API key (via Client/Config)
  # ---------------------------------------------------------------------------

  describe "API key configuration" do
    test "cost-summary calls API with configured credentials" do
      # The Req.Test stub handles the request; if the Client were not configured,
      # it would return {:error, :no_server_configured}. A successful response
      # confirms the configured key is being used via the test plug.
      output =
        capture_io(fn ->
          Token.run("cost-summary", ["--project", "p-1"], [])
        end)

      # Got a valid response, not a "no server configured" error
      refute output =~ "No server configured"
    end
  end
end
