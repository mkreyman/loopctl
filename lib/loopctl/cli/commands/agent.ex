defmodule Loopctl.CLI.Commands.Agent do
  @moduledoc """
  CLI commands for agent operations.

  Commands:
  - `loopctl agent register --name <name> --type <type>`
  - `loopctl contract <story_id>`
  - `loopctl claim <story_id>`
  - `loopctl start <story_id>`
  - `loopctl report <story_id> --artifact <json>`
  - `loopctl unclaim <story_id>`
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches agent subcommands and top-level agent action commands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("agent", args, opts) do
    case args do
      ["register" | rest] -> register(rest, opts)
      _ -> Output.error("Usage: loopctl agent register --name <name> --type <type>")
    end
  end

  def run("contract", [story_id | _rest], opts) do
    case Client.get("/api/v1/stories/#{story_id}", opts) do
      {:ok, %{"story" => story}} ->
        title = story["title"]
        ac_count = length(story["acceptance_criteria"] || [])
        Output.success("Story: #{title}")
        Output.success("Acceptance Criteria: #{ac_count}")

        body = %{"story_title" => title, "ac_count" => ac_count}

        case Client.post("/api/v1/stories/#{story_id}/contract", body, opts) do
          {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
          {:error, reason} -> handle_error(reason)
        end

      {:ok, _unexpected} ->
        Output.error("Unexpected response format when fetching story #{story_id}")

      {:error, reason} ->
        handle_error(reason)
    end
  end

  def run("claim", [story_id | _rest], opts) do
    case Client.post("/api/v1/stories/#{story_id}/claim", %{}) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run("start", [story_id | _rest], opts) do
    case Client.post("/api/v1/stories/#{story_id}/start", %{}) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run("report", [story_id | rest], opts) do
    parsed = parse_kv_args(rest)
    artifact_json = Map.get(parsed, "artifact")

    body =
      if artifact_json do
        case Jason.decode(artifact_json) do
          {:ok, artifact} -> %{"artifact" => artifact}
          _ -> %{}
        end
      else
        %{}
      end

    case Client.post("/api/v1/stories/#{story_id}/report", body) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run("unclaim", [story_id | _rest], opts) do
    case Client.post("/api/v1/stories/#{story_id}/unclaim", %{}) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run(command, _args, _opts) do
    Output.error("Usage: loopctl #{command} <story_id>")
  end

  defp register(args, opts) do
    parsed = parse_kv_args(args)
    name = Map.get(parsed, "name")
    type = Map.get(parsed, "type")

    if name && type do
      body = %{"name" => name, "agent_type" => type}

      case Client.post("/api/v1/agents/register", body) do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    else
      Output.error("Usage: loopctl agent register --name <name> --type <type>")
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
