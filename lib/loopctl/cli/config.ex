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

  @typedoc """
  Reads a single OS environment variable by name, returning its value or `nil`.
  Defaults to `System.get_env/1`; injected in tests so env overrides can be exercised
  WITHOUT `System.put_env`, which mutates BEAM-global OS env shared by every process
  (a flake in an `async: true` suite — two tests overriding `LOOPCTL_SERVER` race).
  """
  @type env_getter :: (String.t() -> String.t() | nil)

  @doc """
  Reads the full configuration, merging file and environment overrides.
  Environment variables take precedence over file values.

  `env_getter` is the OS-env reader (default `System.get_env/1`); pass a map-backed getter
  in tests to inject overrides without touching BEAM-global env.
  """
  @spec read(env_getter()) :: map()
  def read(env_getter \\ &System.get_env/1) do
    file_config = read_file()

    Enum.reduce(@env_overrides, file_config, fn {key, env_var}, acc ->
      case env_getter.(env_var) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  Gets a specific configuration value by key.
  Returns `nil` if the key is not set.

  `env_getter` is threaded to `read/1` (default `System.get_env/1`).
  """
  @spec get(String.t(), env_getter()) :: String.t() | nil
  def get(key, env_getter \\ &System.get_env/1)

  def get(key, env_getter) when key in @valid_keys do
    Map.get(read(env_getter), key)
  end

  def get(_key, _env_getter), do: nil

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
