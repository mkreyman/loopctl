defmodule Loopctl.CLI.Commands.Webhooks do
  @moduledoc """
  CLI commands for webhooks, audit log, and change feed.

  Commands:
  - `loopctl webhook create --url <url> --events <list>`
  - `loopctl webhook list`
  - `loopctl webhook delete <id>`
  - `loopctl webhook test <id>`
  - `loopctl history <story_id>`
  - `loopctl audit --project <project> --since <date>`
  - `loopctl changes --project <project> --since <timestamp>`
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches webhook, audit, history, and changes commands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("webhook", args, opts) do
    case args do
      ["create" | rest] -> webhook_create(rest, opts)
      ["list"] -> webhook_list(opts)
      ["delete", id] -> webhook_delete(id, opts)
      ["test", id] -> webhook_test(id, opts)
      _ -> Output.error("Usage: loopctl webhook create|list|delete|test")
    end
  end

  def run("history", [story_id | _rest], opts) do
    case Client.get("/api/v1/stories/#{story_id}/history") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run("audit", args, opts) do
    parsed = parse_kv_args(args)
    params = build_audit_params(parsed)

    case Client.get("/api/v1/audit", params: params) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run("changes", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")
    since = Map.get(parsed, "since")

    params =
      []
      |> maybe_add_param("project_id", project_id)
      |> maybe_add_param("since", since)

    case Client.get("/api/v1/changes", params: params) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl webhook|history|audit|changes")
  end

  defp webhook_create(args, opts) do
    parsed = parse_kv_args(args)
    url = Map.get(parsed, "url")
    events_str = Map.get(parsed, "events")

    if url && events_str do
      events = String.split(events_str, ",", trim: true)
      body = %{"url" => url, "events" => events}

      case Client.post("/api/v1/webhooks", body) do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    else
      Output.error("Usage: loopctl webhook create --url <url> --events <event1,event2>")
    end
  end

  defp webhook_list(opts) do
    case Client.get("/api/v1/webhooks") do
      {:ok, result} ->
        Output.render(result,
          format: Keyword.get(opts, :format),
          headers: ["id", "url", "events", "active"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp webhook_delete(id, _opts) do
    case Client.delete("/api/v1/webhooks/#{id}") do
      {:ok, _} -> Output.success("Webhook #{id} deleted")
      {:error, reason} -> handle_error(reason)
    end
  end

  defp webhook_test(id, opts) do
    case Client.post("/api/v1/webhooks/#{id}/test", %{}) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp build_audit_params(parsed) do
    []
    |> maybe_add_param("project_id", Map.get(parsed, "project"))
    |> maybe_add_param("entity_type", Map.get(parsed, "entity-type"))
    |> maybe_add_param("action", Map.get(parsed, "action"))
    |> maybe_add_param("from", Map.get(parsed, "since"))
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
