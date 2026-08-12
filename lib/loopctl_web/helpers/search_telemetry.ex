defmodule LoopctlWeb.Helpers.SearchTelemetry do
  @moduledoc """
  The one writer of `search_events` rows from the CONTROLLER layer (#658).

  `Loopctl.Knowledge.maybe_record_search_access/5` records searches that reach the search
  path. Anything refused earlier — a bad cursor, an empty query, an unparseable
  `project_id` — never gets there, and a table whose purpose is making failed searches
  visible must not be blind to the failures the API itself raises.

  Lives here rather than in one controller because every search-shaped endpoint needs the
  identical row: a second copy drifts, and the endpoint with the stale copy is the one
  whose rows read as "this surface never fails".
  """

  alias Loopctl.Knowledge.Analytics
  alias LoopctlWeb.Helpers.ClientContext

  @doc """
  Record one search ATTEMPT for `conn`, merging the server-derived identity over any
  client-asserted context.

  Never raises and never returns an error: telemetry must not be able to fail a search
  (or fail an error response, which is where this is most often called from).
  """
  @spec record_attempt(Plug.Conn.t(), map()) :: :ok
  def record_attempt(conn, attrs) do
    api_key = conn.assigns[:current_api_key]

    if api_key do
      Analytics.record_search_attempt(
        api_key.tenant_id,
        ClientContext.attrs(conn)
        |> Map.merge(%{api_key_id: api_key.id, agent_id: Map.get(api_key, :agent_id)})
        |> Map.merge(attrs)
      )
    end

    :ok
  rescue
    _ -> :ok
  end
end
