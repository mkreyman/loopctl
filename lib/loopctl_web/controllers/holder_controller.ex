defmodule LoopctlWeb.HolderController do
  @moduledoc """
  Session holders (US-52.13): a session registers, heartbeats and ends.

  - `POST /api/v1/holders` — register the calling session and mint its credential.
  - `POST /api/v1/holders/:id/heartbeat` — renew the lease, by the holder's own credential.
  - `POST /api/v1/holders/:id/end` — end the holder and revoke its credential.

  ## Who may register

  The caller is the agent account's plain key (`LOOPCTL_AGENT_KEY`): an unlineaged key with an
  `agent_id`. Minting an unlineaged `:agent` key of the caller's own agent crosses no lineage
  ceiling and gains no role, so the role gate is `role: :agent`. Two refusals keep that true:

    * a key that already IS a holder's credential is answered with its holder and no new
      credential, BEFORE the lineage gate, because a runner session's key (US-52.15) is
      dispatch-minted and would otherwise be refused for asking who it is;
    * any other lineaged key is refused `403 holder_mint_forbidden`
      (`LoopctlWeb.Plugs.RequireUnlineagedCaller`): a credential that carries no lineage may only
      be minted by a principal that has none.

  Register is human-anchored like every other credential mint on a custody tenant. Heartbeat
  and end are not: they act only on the caller's own holder, and a session must be able to end
  itself on any tenant. None of the three is custody surface (`LoopctlWeb.CustodySurface`), so a
  custody halt does not strand a session's lease.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.HolderSchemas
  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Holders
  alias Loopctl.Holders.Holder
  alias Plug.Conn.Status

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]
  plug :answer_holder_bound_caller when action in [:create]

  plug LoopctlWeb.Plugs.RequireUnlineagedCaller,
       [
         code: "holder_mint_forbidden",
         message:
           "Your key was minted by a dispatch, so it sits inside a lineage, and a holder " <>
             "credential belongs to none. Runner sessions are holders already.",
         remedy: "runner sessions are holders already; use the key your dispatch gave you"
       ]
       when action in [:create]

  tags(["Holders"])

  @errors %{
    401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
    403 =>
      {"insufficient_role, custody_tier_required (register), or holder_mint_forbidden " <>
         "(register by a dispatch-minted key)", "application/json", Schemas.ErrorResponse},
    404 => {"Not your holder", "application/json", Schemas.ErrorResponse},
    409 =>
      {"holder_ended, or holder_lease_expired (heartbeat after the lease ran out)",
       "application/json", Schemas.ErrorResponse},
    422 =>
      {"agent_required (the key names no agent), or invalid fields", "application/json",
       Schemas.ErrorResponse}
  }

  operation(:create,
    summary: "Register this session as a holder",
    description:
      "Creates a holder for the calling key's agent and the given `session_id`, and mints its " <>
        "credential: an `:agent` key carrying the holder's id, returned ONCE, expiring at " <>
        "`lease_until` plus one heartbeat interval. 201 on a new holder. A register retried " <>
        "for a live holder of the same session answers 200 with the SAME holder and a NEW " <>
        "credential, revoking the previous one. A key that is already a holder's credential " <>
        "gets 200 with its holder and `credential: null`. 403 holder_mint_forbidden for a " <>
        "dispatch-minted key; 422 agent_required for a key with no agent. `kind` is " <>
        "interactive or cloud. Role: agent+, human-anchored tenant.",
    request_body: {"Session", "application/json", HolderSchemas.RegisterRequest},
    responses:
      Map.merge(@errors, %{
        200 => {"Existing holder", "application/json", HolderSchemas.RegisterResponse},
        201 => {"New holder", "application/json", HolderSchemas.RegisterResponse}
      })
  )

  operation(:heartbeat,
    summary: "Renew a holder's lease",
    description:
      "By the holder's own credential only: sets `last_seen_at` to now, `lease_until` to now " <>
        "plus the lease, moves the credential's expiry to the new lease plus one heartbeat " <>
        "interval, and moves every uncapped claim the holder holds to the new lease. Any other " <>
        "caller gets 404. 409 holder_ended on an ended holder. 409 holder_lease_expired when " <>
        "the lease had already run out: that heartbeat ENDS the holder (lapsed), revokes the " <>
        "credential and releases its claims, so register again. Role: agent+.",
    parameters: [id: [in: :path, type: :string, description: "Holder id"]],
    responses:
      Map.put(@errors, 200, {"Lease", "application/json", HolderSchemas.HeartbeatResponse})
  )

  operation(:end_holder,
    summary: "End a holder",
    description:
      "By the holder's own credential only: sets `ended_at`, revokes the credential and " <>
        "releases each uncapped claim the holder holds, in one transaction. A repeated end answers 200 with the ended holder and writes nothing " <>
        "(it is reachable only while the revoked key is still cached; afterwards it is 401). " <>
        "Any other caller gets 404. Role: agent+.",
    parameters: [id: [in: :path, type: :string, description: "Holder id"]],
    responses: Map.put(@errors, 200, {"Holder", "application/json", HolderSchemas.HolderResponse})
  )

  @doc "POST /api/v1/holders"
  def create(conn, params) do
    api_key = conn.assigns.current_api_key

    case api_key.agent_id do
      nil ->
        error(conn, :unprocessable_entity, "agent_required", "This key names no agent.")

      agent_id ->
        register(conn, api_key.tenant_id, agent_id, params)
    end
  end

  defp register(conn, tenant_id, agent_id, params) do
    attrs = Map.take(params, ["kind", "session_id", "host", "worktree"])
    opts = LoopctlWeb.AuditContext.from_conn(conn)

    with {:ok, result} <- Holders.register(tenant_id, agent_id, attrs, opts) do
      status = if result.outcome == :created, do: :created, else: :ok

      conn
      |> put_status(status)
      |> json(%{
        holder: holder_json(result.holder),
        credential: credential_json(result),
        heartbeat_seconds: Holders.heartbeat_seconds()
      })
    end
  end

  @doc "POST /api/v1/holders/:id/heartbeat"
  def heartbeat(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key

    case Holders.heartbeat(api_key.tenant_id, api_key, id) do
      {:ok, holder} ->
        json(conn, %{
          lease_until: holder.lease_until,
          heartbeat_seconds: Holders.heartbeat_seconds()
        })

      {:error, :holder_ended} ->
        holder_ended(conn)

      {:error, _} = error ->
        error
    end
  end

  @doc "POST /api/v1/holders/:id/end"
  def end_holder(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    opts = LoopctlWeb.AuditContext.from_conn(conn)

    with {:ok, holder} <- Holders.end_holder(api_key.tenant_id, api_key, id, opts) do
      json(conn, %{holder: holder_json(holder)})
    end
  end

  # A key that is already a holder's credential asks who it is: answer with its holder and no
  # new credential. Runs before the lineage gate, because a runner session's credential is
  # dispatch-minted (US-52.15).
  defp answer_holder_bound_caller(conn, _opts) do
    api_key = conn.assigns.current_api_key

    case api_key.holder_id do
      nil ->
        conn

      holder_id ->
        case Holders.get_holder(api_key.tenant_id, holder_id) do
          {:ok, %Holder{ended_at: nil} = holder} ->
            conn
            |> json(%{
              holder: holder_json(holder),
              credential: nil,
              heartbeat_seconds: Holders.heartbeat_seconds()
            })
            |> halt()

          _ended_or_gone ->
            conn |> holder_ended() |> halt()
        end
    end
  end

  defp holder_ended(conn) do
    error(conn, :conflict, "holder_ended", "This holder has ended; register the session again.")
  end

  defp error(conn, status, code, message) do
    status_code = Status.code(status)

    conn
    |> put_status(status)
    |> json(%{error: %{status: status_code, code: code, message: message}})
  end

  defp holder_json(%Holder{} = holder) do
    %{
      id: holder.id,
      agent_id: holder.agent_id,
      kind: holder.kind,
      session_id: holder.session_id,
      host: holder.host,
      worktree: holder.worktree,
      dispatch_id: holder.dispatch_id,
      last_seen_at: holder.last_seen_at,
      lease_until: holder.lease_until,
      ended_at: holder.ended_at,
      ended_reason: holder.ended_reason
    }
  end

  defp credential_json(%{raw_key: raw_key, api_key: api_key}) do
    %{
      raw_key: raw_key,
      api_key_id: api_key.id,
      key_prefix: api_key.key_prefix,
      expires_at: api_key.expires_at
    }
  end
end
