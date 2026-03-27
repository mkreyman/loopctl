defmodule Loopctl.CLI.Commands.Config do
  @moduledoc """
  CLI command module for configuration management.

  Commands:
  - `loopctl config set <key> <value>` -- set a config value
  - `loopctl config get <key>` -- get a config value
  - `loopctl config show` -- show all config values
  """

  alias Loopctl.CLI.Config, as: Cfg
  alias Loopctl.CLI.Output

  @doc """
  Dispatches config subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("config", args, opts) do
    case args do
      ["set", key, value] -> set(key, value, opts)
      ["get", key] -> get_value(key, opts)
      ["show"] -> show(opts)
      _ -> Output.error("Usage: loopctl config set|get|show")
    end
  end

  defp set(key, value, _opts) do
    case Cfg.set(key, value) do
      :ok ->
        Output.success("Config #{key} set to #{value}")

      {:error, {:invalid_key, k}} ->
        Output.error("Invalid config key: #{k}. Valid keys: #{Enum.join(Cfg.valid_keys(), ", ")}")
    end
  end

  defp get_value(key, opts) do
    case Cfg.get(key) do
      nil ->
        Output.error("Config key '#{key}' is not set")

      value ->
        format = Keyword.get(opts, :format, Cfg.format())
        Output.render(%{"key" => key, "value" => value}, format: format)
    end
  end

  defp show(opts) do
    config = Cfg.read()
    format = Keyword.get(opts, :format, Cfg.format())
    Output.render(config, format: format)
  end
end
