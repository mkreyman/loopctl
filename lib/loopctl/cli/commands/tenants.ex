defmodule Loopctl.CLI.Commands.Tenants do
  @moduledoc """
  CLI commands for tenant management.

  Commands:
  - `loopctl tenant register --name <name> --email <email>` -- register tenant
  - `loopctl tenant info` -- current tenant info
  - `loopctl tenant update --setting <key>=<value>` -- update tenant settings
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches tenant subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("tenant", args, opts) do
    case args do
      ["register" | rest] -> register(rest, opts)
      ["info"] -> info(opts)
      ["update" | rest] -> update(rest, opts)
      _ -> Output.error("Usage: loopctl tenant register|info|update")
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl tenant register|info|update")
  end

  defp register(args, opts) do
    parsed = parse_kv_args(args)
    name = Map.get(parsed, "name")
    email = Map.get(parsed, "email")
    slug = Map.get(parsed, "slug")

    if name && email do
      body =
        %{"name" => name, "email" => email}
        |> maybe_put("slug", slug)

      case Client.post("/api/v1/tenants/register", body) do
        {:ok, result} ->
          Output.render(result, format: Keyword.get(opts, :format))

        {:error, :no_server_configured} ->
          Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")

        {:error, {status, body}} ->
          Output.error("Server returned #{status}: #{inspect(body)}")
      end
    else
      Output.error("Usage: loopctl tenant register --name <name> --email <email> [--slug <slug>]")
    end
  end

  defp info(opts) do
    case Client.get("/api/v1/tenants/me") do
      {:ok, body} ->
        Output.render(body, format: Keyword.get(opts, :format))

      {:error, :no_server_configured} ->
        Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")

      {:error, {status, body}} ->
        Output.error("Server returned #{status}: #{inspect(body)}")
    end
  end

  defp update(args, opts) do
    settings =
      args
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.reduce(%{}, fn
        ["--setting", kv], acc ->
          case String.split(kv, "=", parts: 2) do
            [k, v] -> Map.put(acc, k, maybe_parse_value(v))
            _ -> acc
          end

        _, acc ->
          acc
      end)

    if map_size(settings) == 0 do
      Output.error("Usage: loopctl tenant update --setting <key>=<value>")
    else
      case Client.patch("/api/v1/tenants/me", %{"settings" => settings}) do
        {:ok, body} ->
          Output.render(body, format: Keyword.get(opts, :format))

        {:error, :no_server_configured} ->
          Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")

        {:error, {status, body}} ->
          Output.error("Server returned #{status}: #{inspect(body)}")
      end
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_parse_value("true"), do: true
  defp maybe_parse_value("false"), do: false

  defp maybe_parse_value(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> v
    end
  end
end
