defmodule LoopctlWeb.DispatchController do
  @moduledoc """
  US-26.2.1 — REST API for dispatch lineage management.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Auth.Role
  alias Loopctl.Dispatches

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:create]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :index, :enrolled_keys]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]

  @doc "POST /api/v1/dispatches"
  def create(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    parent_id = params["parent_dispatch_id"]

    # Role ceiling: a dispatch may not be minted at a HIGHER privilege than the
    # caller's own key. Without this an orchestrator (or any holder of an attestation
    # over an agent key) could mint a `:user`-role dispatch bearing that key, escaping
    # the role hierarchy — the attestation authorizes the KEY, it must not silently
    # elevate the key's PRIVILEGE. A higher requested role is 403'd here.
    if role_exceeds_caller?(conn, params["role"]) do
      reject_role_ceiling(conn, params["role"])
    else
      # G6: Non-root dispatches must provide their parent's dispatch ID.
      # The parent must be active (not revoked, not expired). Root dispatches
      # (parent_id is nil) are only created at tenant signup.
      if parent_id do
        validate_parent_and_create(conn, tenant_id, parent_id, params)
      else
        do_create_dispatch(conn, tenant_id, params)
      end
    end
  end

  # True only when the requested role parses to a KNOWN role strictly above the
  # caller's. An unparseable/absent role is left to `create_dispatch` to reject with
  # its own `:invalid_role` error (this guard is a ceiling, not a validator).
  defp role_exceeds_caller?(conn, requested) do
    caller_role = conn.assigns.current_api_key.role

    case parse_requested_role(requested) do
      {:ok, role} -> not Role.role_at_least?(caller_role, role)
      :error -> false
    end
  end

  defp parse_requested_role(role) when role in ["agent", "orchestrator", "user", "superadmin"],
    do: {:ok, String.to_existing_atom(role)}

  defp parse_requested_role(role) when role in [:agent, :orchestrator, :user, :superadmin],
    do: {:ok, role}

  defp parse_requested_role(_), do: :error

  defp reject_role_ceiling(conn, requested) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "dispatch_role_exceeds_caller",
        message:
          "A dispatch cannot be minted at a higher role (#{inspect(requested)}) than the " <>
            "caller's own key (#{conn.assigns.current_api_key.role}). Mint the dispatch at " <>
            "the caller's role or lower.",
        remediation: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}
      }
    })
  end

  defp validate_parent_and_create(conn, tenant_id, parent_id, params) do
    case Dispatches.get_dispatch(tenant_id, parent_id) do
      {:ok, parent} ->
        now = DateTime.utc_now()

        if parent.revoked_at || DateTime.compare(parent.expires_at, now) != :gt do
          conn
          |> put_status(:forbidden)
          |> json(%{
            error: %{
              code: "parent_dispatch_expired",
              status: 403,
              message: "Parent dispatch is expired or revoked"
            }
          })
        else
          do_create_dispatch(conn, tenant_id, params)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Parent dispatch not found", status: 404}})
    end
  end

  defp do_create_dispatch(conn, tenant_id, params) do
    case Dispatches.create_dispatch(tenant_id, params) do
      {:ok, %{dispatch: dispatch, raw_key: raw_key}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            dispatch: serialize(dispatch),
            api_key: %{
              raw_key: raw_key,
              role: dispatch.role,
              agent_id: dispatch.agent_id,
              expires_at: dispatch.expires_at
            },
            next_action: %{
              description:
                "Pass the raw_key to the sub-agent via launch arguments. Never store it.",
              learn_more: "https://loopctl.com/wiki/dispatch-lineage"
            }
          }
        })

      {:error, :parent_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Parent dispatch not found", status: 404}})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      # LCP-1 §9.2 enrollment-attestation failures — each is a DISTINCT condition
      # whose client recovery differs, so map them to descriptive bodies with stable
      # codes rather than collapsing to one opaque 422 (mirrors RequireSignedClaim).
      {:error, reason}
      when reason in [
             :attestation_required,
             :owner_key_not_registered,
             :attestation_alg_mismatch,
             :malformed_attestation_encoding
           ] ->
        render_attestation_error(conn, reason)

      {:error, {:attestation_invalid, _detail}} ->
        render_attestation_error(conn, :attestation_invalid)

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{message: "Dispatch creation failed", status: 422}})
    end
  end

  # 409 when the tenant must FIRST register an owner key (a precondition the caller
  # can fix without touching this request); 422 for the malformed/invalid/missing
  # attestation shapes (the caller must fix the attestation it supplied).
  defp render_attestation_error(conn, :owner_key_not_registered) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "owner_key_not_registered",
        message:
          "Enrolling an agent key requires a §9.2 authorizer. This tenant has no owner " <>
            "key registered and this dispatch has no active enrolled parent to delegate " <>
            "from. Register an owner key (POST /api/v1/tenants/me/custody-owner-key) first.",
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  defp render_attestation_error(conn, reason) do
    {code, message} = attestation_error_detail(reason)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: Atom.to_string(code),
        message: message,
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  defp attestation_error_detail(:attestation_required),
    do:
      {:attestation_required,
       "Enrolling an agent key requires a §9.2 owner/parent attestation over that key. " <>
         "Include the `attestation` (owner/parent signature) in the request."}

  defp attestation_error_detail(:attestation_alg_mismatch),
    do:
      {:attestation_alg_mismatch,
       "The dispatch `alg` does not match the authorizing key's algorithm (LCP-1 §6.1). " <>
         "Sign the attestation with, and declare, the authorizer's algorithm."}

  defp attestation_error_detail(:malformed_attestation_encoding),
    do:
      {:malformed_attestation_encoding,
       "The `attestation` could not be decoded: send it as raw 64-byte signature " <>
         "bytes or a 128-character hex string."}

  defp attestation_error_detail(:attestation_invalid),
    do:
      {:attestation_invalid,
       "The owner/parent attestation did not verify against the authorizing key " <>
         "(LCP-1 §9.2). Re-sign the exact tenant/agent-pubkey/lineage/conditions preimage."}

  @doc "GET /api/v1/dispatches/:id"
  def show(conn, %{"id" => id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Dispatches.get_dispatch(tenant_id, id) do
      {:ok, dispatch} ->
        json(conn, %{data: serialize(dispatch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  @doc "GET /api/v1/dispatches"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add(:role, params["role"])
      |> maybe_add(:active_only, params["active_only"] == "true")
      |> maybe_add(:limit, parse_int(params["limit"]))
      |> maybe_add(:offset, parse_int(params["offset"]))

    result = Dispatches.list_dispatches(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &serialize/1),
      meta: result.meta
    })
  end

  @doc """
  GET /api/v1/dispatches/enrolled-keys

  LCP-1 §9.1.1 transparency: the enrolled agent-key set reconstructed from the
  hash-chained audit log (not the dispatches table). Keyset-paged via `cursor`.
  Read-only; a tenant compares this against the keys it generated to detect any
  operator-minted key.
  """
  def enrolled_keys(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add(:limit, parse_int(params["limit"]))
      |> maybe_add(:cursor, parse_int(params["cursor"]))

    result = Dispatches.enrolled_agent_keys(tenant_id, opts)
    json(conn, result)
  end

  defp serialize(d) do
    %{
      id: d.id,
      tenant_id: d.tenant_id,
      parent_dispatch_id: d.parent_dispatch_id,
      agent_id: d.agent_id,
      story_id: d.story_id,
      role: d.role,
      lineage_path: d.lineage_path,
      expires_at: d.expires_at,
      revoked_at: d.revoked_at,
      created_at: d.created_at
    }
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, false), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
