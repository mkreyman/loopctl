defmodule LoopctlWeb.AuditSthController do
  @moduledoc """
  US-26.1.2 — Public endpoint for retrieving Signed Tree Heads.

  No authentication required. STHs are designed for public verification.
  """

  use LoopctlWeb, :controller

  alias Loopctl.AuditChain

  @doc """
  GET /api/v1/audit/sth/:tenant_id

  Returns the latest STH for the tenant. Optionally, pass `?at=<position>`
  to get the smallest STH covering that chain position.
  """
  def show(conn, %{"tenant_id" => tenant_id} = params) do
    case cast_tenant_id(tenant_id) do
      {:ok, tenant_id} -> render_sth(conn, tenant_id, params)
      :error -> bad_tenant_id(conn)
    end
  end

  # `tenant_id` is a raw path segment on a PUBLIC, unauthenticated route, compared
  # against a `:binary_id` column — a non-UUID segment raised `Ecto.Query.CastError`
  # and 500'd. Both actions parse and range-guard `position` carefully; the tenant
  # segment was not guarded at all.
  defp cast_tenant_id(tenant_id), do: Ecto.UUID.cast(tenant_id)

  defp bad_tenant_id(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{message: "tenant_id must be a UUID", code: "invalid_tenant_id", status: 400}
    })
  end

  defp render_sth(conn, tenant_id, params) do
    sth =
      case Map.get(params, "at") do
        nil ->
          AuditChain.get_latest_sth(tenant_id)

        at_str ->
          case Integer.parse(at_str) do
            {position, ""} -> AuditChain.get_sth_at_position(tenant_id, position)
            _ -> nil
          end
      end

    case sth do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})

      sth ->
        json(conn, %{
          data: %{
            tenant_id: sth.tenant_id,
            chain_position: sth.chain_position,
            merkle_root: Base.url_encode64(sth.merkle_root, padding: false),
            signed_at: sth.signed_at,
            signature: Base.url_encode64(sth.signature, padding: false)
          }
        })
    end
  end

  @doc """
  GET /api/v1/audit/sth/:tenant_id/inclusion/:position

  US-41.7 (AC-41.7.4) — the merkle audit path proving the entry at `position` is
  included in the STH this same endpoint publishes. Public and unauthenticated
  for the same reason the STH is: an inclusion proof is verifiable evidence, not
  tenant content. It carries HASHES and the already-published STH only — never a
  chain entry's payload.

  No parallel signing scheme: the proof folds up to the `merkle_root` inside the
  existing ed25519-signed tree head, checkable with
  `Loopctl.AuditChain.Verifier.verify_inclusion/3` plus the tenant's public audit
  key from `GET /api/v1/tenants/:id/audit_public_key`.
  """
  def inclusion(conn, %{"tenant_id" => tenant_id, "position" => position_str}) do
    case cast_tenant_id(tenant_id) do
      {:ok, tenant_id} -> render_inclusion(conn, tenant_id, position_str)
      :error -> bad_tenant_id(conn)
    end
  end

  defp render_inclusion(conn, tenant_id, position_str) do
    parsed =
      case Integer.parse(position_str) do
        {position, ""} -> position
        _ -> nil
      end

    case AuditChain.inclusion_proof(tenant_id, parsed) do
      {:ok, proof} ->
        json(conn, %{data: render_proof(proof)})

      {:error, :not_yet_included} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            message:
              "Entry exists but no signed tree head covers it yet — retry after the next STH.",
            code: "not_yet_included",
            status: 409
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  defp render_proof(proof) do
    %{
      leaf_index: proof.leaf_index,
      leaf_hash: encode(proof.leaf_hash),
      tree_size: proof.tree_size,
      audit_path:
        Enum.map(proof.audit_path, fn %{position: side, hash: hash} ->
          %{position: to_string(side), hash: encode(hash)}
        end),
      sth: %{
        tenant_id: proof.sth.tenant_id,
        chain_position: proof.sth.chain_position,
        merkle_root: encode(proof.sth.merkle_root),
        signed_at: proof.sth.signed_at,
        signature: encode(proof.sth.signature)
      }
    }
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
end
