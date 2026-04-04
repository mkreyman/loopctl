defmodule Loopctl.CLI.Commands.Token do
  @moduledoc """
  CLI commands for token cost analytics.

  Commands:
  - `loopctl cost-summary --project <name|id>` -- project cost overview
  - `loopctl cost-summary --project <name|id> --by-epic` -- per-epic breakdown
  - `loopctl cost-summary --project <name|id> --by-agent` -- per-agent breakdown
  - `loopctl token-report --story <id>` -- detailed story token usage
  - `loopctl anomalies --project <name|id>` -- unresolved anomalies
  - `loopctl anomalies --project <name|id> --include-resolved` -- all anomalies
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output
  alias Loopctl.TokenUsage.Formatting

  @doc """
  Dispatches cost-summary, token-report, and anomalies commands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("cost-summary", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")
    format = Keyword.get(opts, :format)

    cond do
      is_nil(project_id) ->
        Output.error("Usage: loopctl cost-summary --project <id>")

      Map.has_key?(parsed, "by-epic") ->
        cost_summary_by_epic(project_id, format)

      Map.has_key?(parsed, "by-agent") ->
        cost_summary_by_agent(project_id, format)

      true ->
        cost_summary_project(project_id, format)
    end
  end

  def run("token-report", args, opts) do
    parsed = parse_kv_args(args)
    story_id = Map.get(parsed, "story")
    format = Keyword.get(opts, :format)

    if story_id do
      token_report(story_id, format)
    else
      Output.error("Usage: loopctl token-report --story <id>")
    end
  end

  def run("anomalies", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")
    include_resolved = Map.has_key?(parsed, "include-resolved")
    format = Keyword.get(opts, :format)

    if project_id do
      list_anomalies(project_id, include_resolved, format)
    else
      Output.error("Usage: loopctl anomalies --project <id>")
    end
  end

  def run(command, _args, _opts) do
    Output.error("Unknown command: #{command}")
  end

  # ---------------------------------------------------------------------------
  # Private — cost-summary
  # ---------------------------------------------------------------------------

  defp cost_summary_project(project_id, format) do
    case Client.get("/api/v1/analytics/projects/#{project_id}") do
      {:ok, %{"data" => data}} -> render_or_json(data, format, &render_project_summary/1)
      {:ok, body} -> Output.render(body, format: format)
      {:error, reason} -> handle_error(reason)
    end
  end

  defp cost_summary_by_epic(project_id, format) do
    params = [{"project_id", project_id}]

    case Client.get("/api/v1/analytics/epics", params: params) do
      {:ok, %{"data" => data}} -> render_or_json(data, format, &render_epic_breakdown/1)
      {:ok, body} -> Output.render(body, format: format)
      {:error, reason} -> handle_error(reason)
    end
  end

  defp cost_summary_by_agent(project_id, format) do
    params = [{"project_id", project_id}]

    case Client.get("/api/v1/analytics/agents", params: params) do
      {:ok, %{"data" => data}} -> render_or_json(data, format, &render_agent_breakdown/1)
      {:ok, body} -> Output.render(body, format: format)
      {:error, reason} -> handle_error(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — token-report
  # ---------------------------------------------------------------------------

  defp token_report(story_id, format) do
    case Client.get("/api/v1/stories/#{story_id}/token-usage") do
      {:ok, %{"data" => data, "totals" => totals}} ->
        render_token_report_or_json(data, totals, format)

      {:ok, body} ->
        Output.render(body, format: format)

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp render_token_report_or_json(data, totals, format) do
    if is_nil(format) or format == "json" do
      Output.render(%{"data" => data, "totals" => totals}, format: format)
    else
      render_token_report(data, totals)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — anomalies
  # ---------------------------------------------------------------------------

  defp list_anomalies(project_id, include_resolved, format) do
    params =
      [{"project_id", project_id}]
      |> maybe_add_param("include_archived", if(include_resolved, do: "true"))

    case Client.get("/api/v1/cost-anomalies", params: params) do
      {:ok, %{"data" => []}} -> Output.success("No token data available")
      {:ok, %{"data" => data}} -> render_or_json(data, format, &render_anomalies/1)
      {:ok, body} -> Output.render(body, format: format)
      {:error, reason} -> handle_error(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — human-readable renderers
  # ---------------------------------------------------------------------------

  defp render_project_summary(data) when is_map(data) do
    print_project_header(data)
    print_top_agents(data["top_agents"] || [])
    print_model_mix(data["model_breakdown"] || data["models"] || [])
  end

  defp render_project_summary(data) do
    IO.puts(inspect(data, pretty: true))
  end

  defp print_project_header(data) do
    total_cost =
      data |> get_int_field(["total_cost_millicents"]) |> Formatting.millicents_to_dollars()

    total_tokens = data |> get_int_field(["total_tokens"]) |> Formatting.format_tokens()
    budget_util = format_budget_util(data["budget_utilization_percent"])

    IO.puts("Project Cost Summary")
    IO.puts(String.duplicate("-", 40))
    IO.puts("Total Cost:         $#{total_cost}")
    IO.puts("Total Tokens:       #{total_tokens}")
    IO.puts("Budget Utilization: #{budget_util}")
  end

  defp format_budget_util(nil), do: "N/A"
  defp format_budget_util(pct), do: "#{pct}%"

  defp print_top_agents([]), do: :ok

  defp print_top_agents(agents) do
    IO.puts("")
    IO.puts("Top Agents by Cost:")

    agents
    |> Enum.take(3)
    |> Enum.each(&print_agent_cost_line/1)
  end

  defp print_agent_cost_line(agent) do
    cost = agent |> get_int_field(["cost_millicents"]) |> Formatting.millicents_to_dollars()
    name = agent["agent_name"] || agent["agent_id"] || "unknown"
    IO.puts("  #{name}  $#{cost}")
  end

  defp print_model_mix([]), do: :ok

  defp print_model_mix(models) do
    IO.puts("")
    IO.puts("Model Mix:")
    Enum.each(models, &print_model_line/1)
  end

  defp print_model_line(m) do
    name = m["model_name"] || m["model"]
    pct = m["percent"] || m["cost_percent"]

    if name do
      pct_str = if pct, do: "#{pct}%", else: ""
      IO.puts("  #{name}  #{pct_str}")
    end
  end

  defp render_epic_breakdown(data) when is_list(data) do
    if data == [] do
      IO.puts("No token data available")
    else
      print_epic_table(data)
    end
  end

  defp render_epic_breakdown(_data) do
    IO.puts("No token data available")
  end

  defp print_epic_table(data) do
    sorted = Enum.sort_by(data, &get_int_field(&1, ["cost_millicents"]), :desc)

    IO.puts("Epic Cost Breakdown")
    IO.puts(String.duplicate("-", 60))
    IO.puts("  Epic                            Cost        Tokens")
    IO.puts(String.duplicate("-", 60))

    Enum.each(sorted, &print_epic_row/1)
  end

  defp print_epic_row(epic) do
    cost = epic |> get_int_field(["cost_millicents"]) |> Formatting.millicents_to_dollars()
    tokens = epic |> get_int_field(["total_tokens"]) |> Formatting.format_tokens()
    title = epic["epic_title"] || epic["title"] || "Epic #{epic["epic_number"] || "?"}"

    title_padded = String.pad_trailing(String.slice(title, 0, 30), 32)
    cost_padded = String.pad_leading("$#{cost}", 10)
    tokens_padded = String.pad_leading(tokens, 10)
    IO.puts("  #{title_padded}#{cost_padded}  #{tokens_padded}")
  end

  defp render_agent_breakdown(data) when is_list(data) do
    if data == [] do
      IO.puts("No token data available")
    else
      print_agent_table(data)
    end
  end

  defp render_agent_breakdown(_data) do
    IO.puts("No token data available")
  end

  defp print_agent_table(data) do
    sorted = Enum.sort_by(data, &get_int_field(&1, ["cost_millicents"]), :desc)

    IO.puts("Agent Cost Breakdown")
    IO.puts(String.duplicate("-", 70))
    IO.puts("  Rank  Agent                    Cost        Tokens      Efficiency")
    IO.puts(String.duplicate("-", 70))

    sorted
    |> Enum.with_index(1)
    |> Enum.each(fn {agent, rank} -> print_agent_row(agent, rank) end)
  end

  defp print_agent_row(agent, rank) do
    cost = agent |> get_int_field(["cost_millicents"]) |> Formatting.millicents_to_dollars()
    tokens = agent |> get_int_field(["total_tokens"]) |> Formatting.format_tokens()
    efficiency = agent["efficiency_rank"] || agent["efficiency_score"] || rank
    name = agent["agent_name"] || agent["name"] || agent["agent_id"] || "unknown"

    rank_padded = String.pad_leading("#{rank}", 4)
    name_padded = String.pad_trailing(String.slice(name, 0, 24), 25)
    cost_padded = String.pad_leading("$#{cost}", 10)
    tokens_padded = String.pad_leading(tokens, 10)

    IO.puts("  #{rank_padded}  #{name_padded}#{cost_padded}  #{tokens_padded}  #{efficiency}")
  end

  defp render_token_report(data, totals) when is_list(data) do
    if data == [] and (is_nil(totals) or get_int_field(totals, ["total_tokens"]) == 0) do
      IO.puts("No token data available")
    else
      print_token_report_header(totals)
      print_token_report_rows(data)
    end
  end

  defp render_token_report(_data, _totals) do
    IO.puts("No token data available")
  end

  defp print_token_report_header(totals) when is_map(totals) do
    total_cost =
      totals |> get_int_field(["total_cost_millicents"]) |> Formatting.millicents_to_dollars()

    total_tokens = totals |> get_int_field(["total_tokens"]) |> Formatting.format_tokens()
    report_count = totals["report_count"] || 0

    IO.puts("Token Usage Report")
    IO.puts(String.duplicate("-", 70))
    IO.puts("Total Cost:    $#{total_cost}")
    IO.puts("Total Tokens:  #{total_tokens}")
    IO.puts("Report Count:  #{report_count}")
    IO.puts("")
  end

  defp print_token_report_header(_totals), do: :ok

  defp print_token_report_rows([]), do: :ok

  defp print_token_report_rows(data) do
    IO.puts("Reports:")
    IO.puts(String.duplicate("-", 70))
    IO.puts("  Phase         Model               Input      Output     Cost")
    IO.puts(String.duplicate("-", 70))
    Enum.each(data, &print_token_row/1)
  end

  defp print_token_row(report) do
    phase = report["phase"] || "other"
    model = report["model_name"] || "unknown"
    cost = report |> get_int_field(["cost_millicents"]) |> Formatting.millicents_to_dollars()
    input = report |> get_int_field(["input_tokens"]) |> Formatting.format_tokens()
    output = report |> get_int_field(["output_tokens"]) |> Formatting.format_tokens()

    phase_padded = String.pad_trailing(phase, 13)
    model_padded = String.pad_trailing(String.slice(model, 0, 18), 19)
    input_padded = String.pad_leading(input, 9)
    output_padded = String.pad_leading(output, 9)

    IO.puts("  #{phase_padded}  #{model_padded}#{input_padded}  #{output_padded}  $#{cost}")
  end

  defp render_anomalies(data) when is_list(data) do
    if data == [] do
      IO.puts("No token data available")
    else
      print_anomalies_table(data)
    end
  end

  defp render_anomalies(_data) do
    IO.puts("No token data available")
  end

  defp print_anomalies_table(data) do
    IO.puts("Cost Anomalies")
    IO.puts(String.duplicate("-", 70))
    IO.puts("  Type                  Story                     Cost")
    IO.puts(String.duplicate("-", 70))
    Enum.each(data, &print_anomaly_row/1)
  end

  defp print_anomaly_row(anomaly) do
    type = anomaly["anomaly_type"] || "unknown"
    story = anomaly["story_title"] || anomaly["story_id"] || "unknown"
    cost = anomaly |> get_int_field(["cost_millicents"]) |> Formatting.millicents_to_dollars()

    type_padded = String.pad_trailing(String.slice(type, 0, 20), 22)
    story_padded = String.pad_trailing(String.slice(story, 0, 25), 26)
    IO.puts("  #{type_padded}  #{story_padded}  $#{cost}")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_or_json(data, format, human_renderer) do
    if is_nil(format) or format == "json" do
      Output.render(%{"data" => data}, format: format)
    else
      human_renderer.(data)
    end
  end

  defp handle_error(:no_server_configured) do
    Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")
  end

  defp handle_error({status, body}) do
    Output.error("Server returned #{status}: #{inspect(body)}")
  end

  defp handle_error(reason) do
    Output.error("Request failed: #{inspect(reason)}")
  end

  defp parse_kv_args(args) do
    parse_kv_args_loop(args, %{})
  end

  defp parse_kv_args_loop([], acc), do: acc

  defp parse_kv_args_loop(["--" <> key | rest], acc) do
    case rest do
      ["--" <> _ | _] ->
        parse_kv_args_loop(rest, Map.put(acc, key, true))

      [value | remaining] ->
        parse_kv_args_loop(remaining, Map.put(acc, key, value))

      [] ->
        Map.put(acc, key, true)
    end
  end

  defp parse_kv_args_loop([_other | rest], acc) do
    parse_kv_args_loop(rest, acc)
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp get_int_field(data, keys) when is_map(data) do
    value = Enum.find_value(keys, fn key -> Map.get(data, key) end)
    coerce_to_int(value)
  end

  defp get_int_field(_data, _keys), do: 0

  defp coerce_to_int(value) when is_integer(value), do: value
  defp coerce_to_int(value) when is_binary(value), do: elem(Integer.parse(value), 0)
  defp coerce_to_int(_value), do: 0
end
