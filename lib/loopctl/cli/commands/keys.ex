defmodule Loopctl.CLI.Commands.Keys do
  @moduledoc """
  CLI commands for API key management.

  Commands:
  - `loopctl keys create --name <name> --role <role>`
  - `loopctl keys list`
  - `loopctl keys revoke <key_id>`
  - `loopctl keys rotate <key_id>`
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches keys subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("keys", args, opts) do
    case args do
      ["create" | rest] -> create(rest, opts)
      ["list"] -> list(opts)
      ["revoke", key_id] -> revoke(key_id, opts)
      ["rotate", key_id] -> rotate(key_id, opts)
      _ -> Output.error("Usage: loopctl keys create|list|revoke|rotate")
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl keys create|list|revoke|rotate")
  end

  defp create(args, opts) do
    parsed = parse_kv_args(args)
    name = Map.get(parsed, "name")
    role = Map.get(parsed, "role")

    if name && role do
      body = %{"name" => name, "role" => role}

      case Client.post("/api/v1/api_keys", body) do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    else
      Output.error("Usage: loopctl keys create --name <name> --role <role>")
    end
  end

  defp list(opts) do
    case Client.get("/api/v1/api_keys") do
      {:ok, result} ->
        format = Keyword.get(opts, :format)

        Output.render(result,
          format: format,
          headers: ["id", "name", "role", "key_prefix"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp revoke(key_id, opts) do
    case Client.delete("/api/v1/api_keys/#{key_id}") do
      {:ok, _result} ->
        Output.render(%{"status" => "revoked", "id" => key_id},
          format: Keyword.get(opts, :format)
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp rotate(key_id, opts) do
    case Client.post("/api/v1/api_keys/#{key_id}/rotate", %{}) do
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
