defmodule Loopctl.CLI.Config do
  @moduledoc """
  Manages CLI configuration stored at `~/.loopctl/config.json`.

  Supports three config keys:
  - `server` -- the loopctl server URL
  - `api_key` -- the API key for authentication
  - `format` -- default output format (json, human, csv)

  Environment variable overrides (checked first):
  - `LOOPCTL_SERVER`
  - `LOOPCTL_API_KEY`
  - `LOOPCTL_FORMAT`
  """

  @config_dir ".loopctl"
  @config_file "config.json"

  @valid_keys ~w(server api_key format)
  @env_overrides %{
    "server" => "LOOPCTL_SERVER",
    "api_key" => "LOOPCTL_API_KEY",
    "format" => "LOOPCTL_FORMAT"
  }

  @doc """
  Returns the path to the config file.
  """
  @spec config_path() :: String.t()
  def config_path do
    Path.join([home_dir(), @config_dir, @config_file])
  end

  @doc """
  Reads the full configuration, merging file and environment overrides.
  Environment variables take precedence over file values.
  """
  @spec read() :: map()
  def read do
    file_config = read_file()

    Enum.reduce(@env_overrides, file_config, fn {key, env_var}, acc ->
      case System.get_env(env_var) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  Gets a specific configuration value by key.
  Returns `nil` if the key is not set.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(key) when key in @valid_keys do
    Map.get(read(), key)
  end

  def get(_key), do: nil

  @doc """
  Sets a configuration value in the config file.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec set(String.t(), String.t()) :: :ok | {:error, term()}
  def set(key, value) when key in @valid_keys do
    config = read_file()
    updated = Map.put(config, key, value)
    write_file(updated)
  end

  def set(key, _value) do
    {:error, {:invalid_key, key}}
  end

  @doc """
  Returns the server URL from config.
  """
  @spec server() :: String.t() | nil
  def server, do: get("server")

  @doc """
  Returns the API key from config.
  """
  @spec api_key() :: String.t() | nil
  def api_key, do: get("api_key")

  @doc """
  Returns the default output format from config.
  Defaults to "json" if not set.
  """
  @spec format() :: String.t()
  def format, do: get("format") || "json"

  @doc """
  Returns the list of valid config keys.
  """
  @spec valid_keys() :: [String.t()]
  def valid_keys, do: @valid_keys

  # --- Private ---

  defp read_file do
    case File.read(config_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp write_file(config) do
    path = config_path()
    dir = Path.dirname(path)
    json = Jason.encode!(config, pretty: true)

    with :ok <- File.mkdir_p(dir) do
      File.write(path, json)
    end
  end

  defp home_dir do
    Application.get_env(:loopctl, :cli_config_dir, System.user_home!())
  end
end
