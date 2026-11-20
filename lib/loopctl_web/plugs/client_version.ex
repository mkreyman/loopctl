defmodule LoopctlWeb.Plugs.ClientVersion do
  @moduledoc """
  Refuses a factory client older than the release set accepts (US-52.8), before any key is
  resolved, so an old client gets the 426 it can act on rather than a 401 it cannot.

  The client names itself in `x-loopctl-client: <component>/<version>`. Only `runner`, `chg`
  and `mcp` are judged, through `Loopctl.ReleaseSet.check/3`. A request without the header,
  with one this plug cannot parse, or naming any other component passes unchanged: other HTTP
  callers (fleet_dash, scripts) are not factory clients and are never refused, and an MCP
  package older than this header sends none.

  This is not `x-loopctl-client-context`, which is analytics-only by its own contract and
  never gates anything (`LoopctlWeb.Helpers.ClientContext`).

  Options: `:components`, the release-set components map, defaulting to the compiled set. A
  test may instead put one in `conn.private[:release_set_components]`; request data never
  reaches either.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.ReleaseSet

  @header "x-loopctl-client"

  @doc "The request header a factory client names itself in."
  @spec header() :: String.t()
  def header, do: @header

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    with [value | _] <- get_req_header(conn, @header),
         {:ok, component, sent} <- parse(value),
         {:error, {:incompatible_client_version, refusal}} <-
           ReleaseSet.check(component, sent, components(conn, opts)) do
      refuse(conn, refusal)
    else
      _ -> conn
    end
  end

  @doc """
  `"<component>/<version>"` as `{:ok, component, version}` when the component is a factory
  client, `:other` otherwise.
  """
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | :other
  def parse(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [component, version] when component in unquote(ReleaseSet.clients()) ->
        {:ok, component, String.trim(version)}

      _ ->
        :other
    end
  end

  defp components(conn, opts) do
    Map.get(conn.private, :release_set_components) ||
      Keyword.get_lazy(opts, :components, &ReleaseSet.components/0)
  end

  defp refuse(conn, refusal) do
    conn
    |> put_status(:upgrade_required)
    |> Phoenix.Controller.json(%{error: body(refusal)})
    |> halt()
  end

  @doc "The 426 `error` object for a refusal."
  @spec body(ReleaseSet.incompatible()) :: map()
  def body(%{component: component, sent: sent, minimum: minimum}) do
    %{
      status: 426,
      code: "incompatible_client_version",
      component: component,
      sent: sent,
      minimum: minimum,
      message:
        "#{component} #{sent} is older than this server's release set accepts " <>
          "(minimum #{minimum}); install the current release and retry"
    }
  end
end
