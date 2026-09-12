defmodule LoopctlWeb.RunnerSocket do
  @moduledoc """
  The authenticated socket runners connect to (issue #801).

  A runner is a CLIENT, never a BEAM cluster peer: it dials out to
  `/runner/socket/websocket` and presents its credential in the
  `x-loopctl-runner-token` header. The credential is never read from connect params,
  because a query string is logged by every proxy between the runner and loopctl.

  ## Not a bypass of the HTTP security pipeline

  A socket does not run the router's plugs, so `connect/3` re-applies the parts that
  carry security weight, through the same functions:

  - `AuthPathThrottle`'s per-IP, fail-CLOSED ceiling (`Loopctl.RateLimiter.gate_ok?/3`,
    same `auth_ip:` bucket), counted BEFORE the key is resolved, so a flood of bad
    tokens cannot turn into unbounded `api_keys` lookups on the AdminRepo pool;
  - `ResolveApiKey`'s resolution (`Auth.verify_api_key/1`: revocation cache, expiry)
    and its refusal of a non-active tenant, via `Loopctl.Runners.authenticate/1`;
  - plus the runner-specific rule: the key must be bound to an active runner row.

  `SetTenant` has no equivalent here on purpose. It writes the RLS tenant into the
  process dictionary of the REQUEST process; a channel is a different, long-lived
  process, and every context call it makes passes `tenant_id` explicitly. The witness
  header and `CheckCustodyHalt` are not applied: the socket carries no audit-chain read
  and no custody operation. Dispatch (#803) will, and must add the halt check there.

  Every refusal answers identically (HTTP 403); the reason goes to the server log only.
  """

  use Phoenix.Socket

  require Logger

  alias Loopctl.RemoteIp
  alias Loopctl.Runners

  @token_header "x-loopctl-runner-token"
  @throttle_window_ms 60_000
  @throttle_max_per_ip 3_000

  channel "runners", LoopctlWeb.RunnerChannel

  @doc "The header a runner presents its credential in."
  @spec token_header() :: String.t()
  def token_header, do: @token_header

  @impl true
  def connect(_params, socket, connect_info) do
    with :ok <- throttle(connect_info),
         {:ok, token} <- fetch_token(connect_info),
         {:ok, %{runner: runner, api_key: api_key}} <- Runners.authenticate(token) do
      {:ok,
       socket
       |> assign(:runner, runner)
       |> assign(:tenant_id, runner.tenant_id)
       |> assign(:api_key_id, api_key.id)}
    else
      {:error, reason} ->
        Logger.info("runner socket refused: #{inspect(reason)}")
        :error
    end
  end

  @impl true
  def id(socket), do: socket_id(socket.assigns.runner.id)

  @doc "The socket id a runner's connection is registered under, for disconnects."
  @spec socket_id(Ecto.UUID.t()) :: String.t()
  def socket_id(runner_id), do: "runner_socket:" <> runner_id

  defp fetch_token(connect_info) do
    headers = Map.get(connect_info, :x_headers, [])

    case for({@token_header, value} <- headers, do: String.trim(value)) do
      [token] when token != "" -> {:ok, token}
      [] -> {:error, :missing_token}
      _ -> {:error, :ambiguous_token}
    end
  end

  # Mirrors `LoopctlWeb.Plugs.AuthPathThrottle`: the same fail-CLOSED gate, the same
  # bucket and ceiling, and the same skip when no stable client IP resolves (keying a
  # shared bucket on a proxy IP would collapse every client onto one budget).
  defp throttle(connect_info) do
    case RemoteIp.bucket_key_tagged(client_ip(connect_info)) do
      {:client, ip} ->
        {window_ms, ceiling} = throttle_limits()

        if Loopctl.RateLimiter.gate_ok?("auth_ip:#{ip}", window_ms, ceiling),
          do: :ok,
          else: {:error, :throttled}

      {:unresolved, _reason} ->
        :ok
    end
  end

  # The plug's own configuration, so one `AUTH_THROTTLE_*` knob tunes both paths.
  defp throttle_limits do
    config = Application.get_env(:loopctl, LoopctlWeb.Plugs.AuthPathThrottle, [])

    {positive_int(config[:window_ms], @throttle_window_ms),
     positive_int(config[:max_requests_per_ip], @throttle_max_per_ip)}
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp client_ip(connect_info) do
    forwarded = RemoteIp.from(Map.get(connect_info, :x_headers, []))

    case {forwarded, Map.get(connect_info, :peer_data)} do
      {nil, %{address: address}} -> address
      {forwarded, _} -> forwarded
    end
  end
end
