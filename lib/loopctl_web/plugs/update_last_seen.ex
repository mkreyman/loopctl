defmodule LoopctlWeb.Plugs.UpdateLastSeen do
  @moduledoc """
  Records the `last_seen_at` timestamp for authenticated agents.

  On every authenticated API call where the API key has an `agent_id`,
  this plug records the corresponding agent's `last_seen_at` touch into the
  debounced `Loopctl.TouchBuffer` (US-33.4). It performs NO synchronous DB write
  on the request path — a supervised periodic flusher persists the buffered
  maxima in a single batched UPDATE. Uses the DI clock for testability.

  The touch is best-effort -- recording never raises and never blocks the
  request pipeline.

  ## Placement

  Must be placed in the router pipeline after `RequireAuth` (which
  ensures `current_api_key` is present in assigns).
  """

  @behaviour Plug

  alias Loopctl.Agents

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %{assigns: %{current_api_key: %{agent_id: agent_id, tenant_id: tenant_id}}} = conn,
        _opts
      )
      when is_binary(agent_id) and is_binary(tenant_id) do
    now = clock().utc_now()
    :ok = Agents.touch_last_seen(tenant_id, agent_id, now)
    conn
  end

  def call(conn, _opts), do: conn

  defp clock do
    Application.get_env(:loopctl, :clock, Loopctl.Clock.Default)
  end
end
