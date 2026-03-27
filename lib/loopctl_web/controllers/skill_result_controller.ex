defmodule LoopctlWeb.SkillResultController do
  @moduledoc """
  Controller for recording skill results.

  - `POST /api/v1/skill_results` -- record a skill result (orchestrator role)
  """

  use LoopctlWeb, :controller

  alias Loopctl.Skills
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: [:orchestrator, :superadmin]

  @doc "POST /api/v1/skill_results"
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    case Skills.create_skill_result(tenant_id, params, audit_opts) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{
          skill_result: %{
            id: result.id,
            skill_version_id: result.skill_version_id,
            verification_result_id: result.verification_result_id,
            story_id: result.story_id,
            metrics: result.metrics,
            inserted_at: result.inserted_at
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end
end
