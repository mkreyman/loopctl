defmodule Loopctl.CLI.Commands.Orchestrator do
  @moduledoc """
  CLI commands for orchestrator operations.

  Commands:
  - `loopctl verify <story_id> --result <pass|fail|partial> --summary <text>`
  - `loopctl reject <story_id> --reason <text>`
  - `loopctl pending --project <project>`
  - `loopctl state save --project <project> --data <json>`
  - `loopctl state load --project <project>`
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches orchestrator subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("verify", [story_id | rest], opts) do
    parsed = parse_kv_args(rest)
    result = Map.get(parsed, "result", "pass")
    summary = Map.get(parsed, "summary", "")

    body = %{"result" => result, "summary" => summary}

    case Client.post("/api/v1/stories/#{story_id}/verify", body) do
      {:ok, result_body} -> Output.render(result_body, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run("reject", [story_id | rest], opts) do
    parsed = parse_kv_args(rest)
    reason = Map.get(parsed, "reason", "")

    body = %{"reason" => reason}

    case Client.post("/api/v1/stories/#{story_id}/reject", body) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason_err} -> handle_error(reason_err)
    end
  end

  def run("pending", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")

    params =
      [
        {"agent_status", "reported_done"},
        {"verified_status", "unverified"}
      ]
      |> maybe_add_param("project_id", project_id)

    case Client.get("/api/v1/stories/ready", params: params) do
      {:ok, result} ->
        Output.render(result,
          format: Keyword.get(opts, :format),
          headers: ["id", "number", "title", "agent_status"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  def run("state", ["save" | rest], opts) do
    parsed = parse_kv_args(rest)
    project_id = Map.get(parsed, "project")
    data_json = Map.get(parsed, "data")
    state_key = Map.get(parsed, "key", "main")

    if project_id && data_json do
      save_state(project_id, data_json, state_key, opts)
    else
      Output.error("Usage: loopctl state save --project <id> --data <json>")
    end
  end

  def run("state", ["load" | rest], opts) do
    parsed = parse_kv_args(rest)
    project_id = Map.get(parsed, "project")
    state_key = Map.get(parsed, "key")
    params = if state_key, do: [{"state_key", state_key}], else: []

    if project_id do
      case Client.get("/api/v1/orchestrator/state/#{project_id}", params: params) do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    else
      Output.error("Usage: loopctl state load --project <id> [--key <state_key>]")
    end
  end

  def run(command, _args, _opts) do
    Output.error("Usage: loopctl #{command} <story_id> [options]")
  end

  defp save_state(project_id, data_json, state_key, opts) do
    case Jason.decode(data_json) do
      {:ok, state_data} ->
        body = %{"state_key" => state_key, "state_data" => state_data}

        case Client.put("/api/v1/orchestrator/state/#{project_id}", body) do
          {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
          {:error, reason} -> handle_error(reason)
        end

      {:error, _} ->
        Output.error("Invalid JSON in --data")
    end
  end

  defp handle_error(:no_server_configured) do
    Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")
  end

  defp handle_error({status, body}) do
    Output.error("Server returned #{status}: #{inspect(body)}")
  end

  defp parse_kv_args(args) do
    args
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.reduce(%{}, fn
      ["--" <> key, value], acc -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]
end
