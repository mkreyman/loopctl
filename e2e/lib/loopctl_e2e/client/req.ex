defmodule LoopctlE2e.Client.Req do
  @moduledoc """
  The live client: loopctl with the orchestrator key, GitHub with the e2e token, both over
  HTTPS (US-52.9 failure_modes.reach). Each request has a 30 s receive timeout, so a slow
  service is one failed poll rather than a hung run.

  Every loopctl request carries the witness header (`LoopctlE2e.Client.Witness`). The cached
  STH lives in an Agent the client starts, so the polls of one run share it.
  """

  @behaviour LoopctlE2e.Client

  alias LoopctlE2e.Client.Witness

  @enforce_keys [:loopctl_url, :loopctl_key, :github_token, :sth]
  defstruct [
    :loopctl_url,
    :loopctl_key,
    :github_token,
    :sth,
    github_url: "https://api.github.com",
    requester: &Req.request/1
  ]

  @type t :: %__MODULE__{}

  @doc """
  A live client from the environment the e2e workflow sets. `opts` may name a `:requester`
  (a function taking Req options), which a test passes in place of `Req.request/1`.
  """
  @spec from_env(map(), keyword()) :: {:ok, LoopctlE2e.Client.t()} | {:error, String.t()}
  def from_env(env \\ System.get_env(), opts \\ []) do
    with {:ok, key} <- fetch(env, "LOOPCTL_E2E_ORCH_KEY"),
         {:ok, token} <- fetch(env, "E2E_GITHUB_TOKEN") do
      {:ok, sth} = Agent.start_link(fn -> nil end)

      conn = %__MODULE__{
        loopctl_url: Map.get(env, "LOOPCTL_E2E_SERVER", "https://loopctl.com"),
        loopctl_key: key,
        github_token: token,
        sth: sth,
        requester: Keyword.get(opts, :requester, &Req.request/1)
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

  defp request(conn, :loopctl, opts) do
    case send_request(conn, :loopctl, opts) do
      {:ok, status, body, sth} ->
        if Witness.retry?(status, body, sth),
          do: conn |> send_request(:loopctl, opts) |> reply(),
          else: {:ok, status, body}

      error ->
        error
    end
  end

  defp request(conn, :github, opts), do: conn |> send_request(:github, opts) |> reply()

  defp reply({:ok, status, body, _sth}), do: {:ok, status, body}
  defp reply(error), do: error

  defp send_request(conn, service, opts) do
    {base, headers} = target(conn, service)

    opts
    |> Keyword.merge(base_url: base, headers: headers, receive_timeout: 30_000, retry: false)
    |> conn.requester.()
    |> case do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        {:ok, status, body, remember(conn, service, resp_headers)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Caches the STH a loopctl response hands back; returns it (nil when there is none).
  defp remember(conn, :loopctl, resp_headers) do
    sth = Witness.current_sth(resp_headers)
    if sth, do: Agent.update(conn.sth, fn _ -> sth end)
    sth
  end

  defp remember(_conn, :github, _resp_headers), do: nil

  defp target(conn, :loopctl) do
    witness = conn.sth |> Agent.get(& &1) |> Witness.headers()
    {conn.loopctl_url, [{"authorization", "Bearer " <> conn.loopctl_key} | witness]}
  end

  defp target(conn, :github) do
    {conn.github_url,
     [
       {"authorization", "Bearer " <> conn.github_token},
       {"accept", "application/vnd.github+json"},
       {"x-github-api-version", "2022-11-28"}
     ]}
  end
end
