defmodule LoopctlRunner.ControlConfig do
  @moduledoc """
  The `control` section of the runner config: how this machine reaches loopctl.

      "control": {
        "url": "wss://loopctl.com/runner/socket/websocket",
        "runner_id": "<uuid from POST /api/v1/runners>",
        "machine": "minis",
        "token_file": "~/.config/loopctl-runner/token",
        "repos": ["mkreyman/home_care_billing"],
        "max_sessions": 2,
        "status_interval_s": 30
      }

  Fails closed like the rest of the config. Three rules carry the security weight:

    * the credential lives in its own file readable by this user alone — never in the
      config JSON, never in the environment a `claude` session inherits, never in a URL
      (loopctl refuses a `?token=`);
    * the URL is `wss://`, except `ws://` to a loopback address for a local loopctl;
    * `machine` must be the name the runner was enrolled under (loopctl refuses any other).
  """

  @enforce_keys [:url, :runner_id, :machine, :token_file, :repos, :max_sessions]
  defstruct [
    :url,
    :runner_id,
    :machine,
    :token_file,
    :repos,
    :max_sessions,
    status_interval_s: 30
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          runner_id: String.t(),
          machine: String.t(),
          token_file: String.t(),
          repos: [String.t()],
          max_sessions: non_neg_integer(),
          status_interval_s: pos_integer()
        }

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  # The contract's own patterns (RunnerJoin.machine, RunnerJoin.repos.items).
  @machine ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  @repo ~r/\A[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}\z/
  @loopback ["127.0.0.1", "::1", "localhost"]

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    with {:ok, url} <- url(map["url"]),
         {:ok, runner_id} <- matching(map, "runner_id", @uuid),
         {:ok, machine} <- matching(map, "machine", @machine),
         {:ok, token_file} <- token_file(map["token_file"]),
         {:ok, repos} <- repos(map["repos"]),
         {:ok, max_sessions} <- int(map, "max_sessions", 0, 64),
         {:ok, interval} <-
           int(Map.put_new(map, "status_interval_s", 30), "status_interval_s", 5, 3600) do
      {:ok,
       %__MODULE__{
         url: url,
         runner_id: runner_id,
         machine: machine,
         token_file: token_file,
         repos: repos,
         max_sessions: max_sessions,
         status_interval_s: interval
       }}
    end
  end

  def from_map(_), do: {:error, "config control must be an object"}

  @doc """
  Reads the token, refusing a file any other user can read: the token lets whoever holds
  it join as this machine and receive its dispatches.
  """
  @spec read_token(t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_token(%__MODULE__{token_file: path}) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         0 <- Bitwise.band(mode, 0o077),
         {:ok, raw} <- File.read(path),
         token when token != "" <- String.trim(raw) do
      {:ok, token}
    else
      {:error, reason} ->
        {:error, "cannot read token file #{path}: #{:file.format_error(reason)}"}

      n when is_integer(n) ->
        {:error, "token file #{path} is readable by other users; chmod 600 it"}

      "" ->
        {:error, "token file #{path} is empty"}

      _ ->
        {:error, "token file #{path} is not a regular file"}
    end
  end

  defp url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "wss", host: host, query: nil} when is_binary(host) and host != "" ->
        {:ok, value}

      %URI{scheme: "ws", host: host, query: nil} when host in @loopback ->
        {:ok, value}

      %URI{query: query} when is_binary(query) ->
        {:error, "config control.url must carry no query string; the token goes in a header"}

      _ ->
        {:error, "config control.url must be wss://, or ws:// to a loopback address"}
    end
  end

  defp url(_), do: {:error, "config control.url must be a string"}

  defp matching(map, key, format) do
    value = map[key]

    if is_binary(value) and value =~ format,
      do: {:ok, value},
      else: {:error, "config control.#{key} is missing or malformed"}
  end

  defp token_file(value) when is_binary(value) and value != "", do: {:ok, Path.expand(value)}
  defp token_file(_), do: {:error, "config control.token_file must be a path"}

  defp repos(list) when is_list(list) and length(list) <= 50 do
    if Enum.all?(list, &(is_binary(&1) and &1 =~ @repo)),
      do: {:ok, list},
      else: {:error, "config control.repos entries must be owner/repo"}
  end

  defp repos(_), do: {:error, "config control.repos must be a list of at most 50 owner/repo"}

  defp int(map, key, min, max) do
    case map[key] do
      n when is_integer(n) and n >= min and n <= max -> {:ok, n}
      _ -> {:error, "config control.#{key} must be an integer from #{min} to #{max}"}
    end
  end
end
