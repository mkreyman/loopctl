defmodule LoopctlWeb.SkillResultController do
  @moduledoc """
  Controller for recording skill results.

  - `POST /api/v1/skill_results` -- record a skill result (orchestrator role)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Skills
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: [:orchestrator, :superadmin]

  tags(["Skills"])

  operation(:create,
    summary: "Record skill result",
    description: "Records a skill execution result. Requires orchestrator role.",
    request_body:
      {"Result params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:skill_version_id, :story_id, :metrics],
         properties: %{
           skill_version_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           verification_result_id: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             nullable: true
           },
           story_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           metrics: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 =>
        {"Result created", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

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
