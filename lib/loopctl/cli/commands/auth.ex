defmodule Loopctl.CLI.Commands.Auth do
  @moduledoc """
  CLI commands for authentication.

  Commands:
  - `loopctl auth login --server <url> --key <key>` -- configure credentials
  - `loopctl auth whoami` -- show current identity
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Config
  alias Loopctl.CLI.Output

  @doc """
  Dispatches auth subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("auth", args, opts) do
    case args do
      ["login" | rest] -> login(rest, opts)
      ["whoami"] -> whoami(opts)
      _ -> Output.error("Usage: loopctl auth login|whoami")
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl auth login|whoami")
  end

  defp login(args, _opts) do
    parsed = parse_kv_args(args)
    server = Map.get(parsed, "server")
    key = Map.get(parsed, "key")

    if is_nil(server) do
      Output.error("Missing --server. Usage: loopctl auth login --server <url> --key <key>")
    else
      validate_and_save_credentials(server, key)
    end
  end

  defp validate_and_save_credentials(server, key) do
    case Client.get("/api/v1/tenants/me", server: server, api_key: key) do
      {:ok, _body} ->
        Config.set("server", server)
        if key, do: Config.set("api_key", key)
        Output.success("Credentials saved. Server: #{server}")

      {:error, {status, body}} ->
        Output.error(
          "Login failed (#{status}): #{inspect(body)}. Check your server URL and API key."
        )

      {:error, reason} ->
        Output.error("Login failed: #{inspect(reason)}. Check your server URL and API key.")
    end
  end

  defp whoami(opts) do
    format = Keyword.get(opts, :format)

    case Client.get("/api/v1/tenants/me") do
      {:ok, body} ->
        Output.render(body, format: format)

      {:error, :no_server_configured} ->
        Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")

      {:error, {status, body}} ->
        Output.error("Server returned #{status}: #{inspect(body)}")
    end
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
