defmodule Loopctl.CLI.Commands.Status do
  @moduledoc """
  CLI commands for progress and status queries.

  Commands:
  - `loopctl status --project <project>` -- project-wide progress
  - `loopctl status --epic <epic_id>` -- epic progress
  - `loopctl status <story_id>` -- story detail
  - `loopctl next --project <project>` -- ready stories
  - `loopctl blocked --project <project>` -- blocked stories
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches status, next, and blocked commands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("status", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")
    epic_id = Map.get(parsed, "epic")
    story_id = List.first(Enum.reject(args, &String.starts_with?(&1, "--")))

    cond do
      project_id -> project_status(project_id, opts)
      epic_id -> epic_status(epic_id, opts)
      story_id -> story_status(story_id, opts)
      true -> Output.error("Usage: loopctl status --project <id> | --epic <id> | <story_id>")
    end
  end

  def run("next", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")
    params = if project_id, do: [{"project_id", project_id}], else: []

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

  def run("blocked", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")
    params = if project_id, do: [{"project_id", project_id}], else: []

    case Client.get("/api/v1/stories/blocked", params: params) do
      {:ok, result} ->
        Output.render(result,
          format: Keyword.get(opts, :format),
          headers: ["id", "number", "title", "agent_status"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl status --project <id> | --epic <id> | <story_id>")
  end

  defp project_status(project_id, opts) do
    case Client.get("/api/v1/projects/#{project_id}/progress") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp epic_status(epic_id, opts) do
    case Client.get("/api/v1/epics/#{epic_id}/progress") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp story_status(story_id, opts) do
    case Client.get("/api/v1/stories/#{story_id}") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
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
end
