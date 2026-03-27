defmodule LoopctlWeb.Plugs.UpdateLastSeen do
  @moduledoc """
  Updates the `last_seen_at` timestamp for authenticated agents.

  On every authenticated API call where the API key has an `agent_id`,
  this plug updates the corresponding agent's `last_seen_at` field.

  The update is best-effort -- failures are logged but do not block
  the request pipeline. Uses the DI clock for testability.

  ## Placement

  Must be placed in the router pipeline after `RequireAuth` (which
  ensures `current_api_key` is present in assigns).
  """

  @behaviour Plug

  require Logger

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

    case Agents.touch_last_seen(tenant_id, agent_id, now) do
      {:ok, _agent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update last_seen_at for agent #{agent_id}: #{inspect(reason)}")
    end

    conn
  end

  def call(conn, _opts), do: conn

  defp clock do
    Application.get_env(:loopctl, :clock, Loopctl.Clock.Default)
  end
end
