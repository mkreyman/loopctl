defmodule LoopctlE2e.Client.Req do
  @moduledoc """
  The live client: loopctl with the orchestrator key, GitHub with the e2e token, both over
  HTTPS (US-52.9 failure_modes.reach). Each request has a 30 s receive timeout, so a slow
  service is one failed poll rather than a hung run.
  """

  @behaviour LoopctlE2e.Client

  @enforce_keys [:loopctl_url, :loopctl_key, :github_token]
  defstruct [:loopctl_url, :loopctl_key, :github_token, github_url: "https://api.github.com"]

  @type t :: %__MODULE__{}

  @doc "A live client from the environment the e2e workflow sets."
  @spec from_env(map()) :: {:ok, LoopctlE2e.Client.t()} | {:error, String.t()}
  def from_env(env \\ System.get_env()) do
    with {:ok, key} <- fetch(env, "LOOPCTL_E2E_ORCH_KEY"),
         {:ok, token} <- fetch(env, "E2E_GITHUB_TOKEN") do
      conn = %__MODULE__{
        loopctl_url: Map.get(env, "LOOPCTL_E2E_SERVER", "https://loopctl.com"),
        loopctl_key: key,
        github_token: token
      }

      {:ok, {__MODULE__, conn}}
    end
  end

  defp fetch(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{name} is not set"}
    end
  end

  @impl true
  def get(conn, service, path, params) do
    request(conn, service, method: :get, url: path, params: params)
  end

  @impl true
  def post(conn, service, path, body) do
    request(conn, service, method: :post, url: path, json: body)
  end

  defp request(conn, service, opts) do
    {base, headers} = target(conn, service)

    opts
    |> Keyword.merge(base_url: base, headers: headers, receive_timeout: 30_000, retry: false)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp target(conn, :loopctl),
    do: {conn.loopctl_url, [{"authorization", "Bearer " <> conn.loopctl_key}]}

  defp target(conn, :github) do
    {conn.github_url,
     [
       {"authorization", "Bearer " <> conn.github_token},
       {"accept", "application/vnd.github+json"},
       {"x-github-api-version", "2022-11-28"}
     ]}
  end
end
