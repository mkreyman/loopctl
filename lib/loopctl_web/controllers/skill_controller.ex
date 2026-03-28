defmodule LoopctlWeb.SkillController do
  @moduledoc """
  Controller for skill management and versioning.

  - `POST /api/v1/skills` -- create skill with v1 (user role)
  - `GET /api/v1/skills` -- list skills (agent+ role)
  - `GET /api/v1/skills/:id` -- get skill (agent+ role)
  - `PATCH /api/v1/skills/:id` -- update metadata (user role)
  - `DELETE /api/v1/skills/:id` -- archive skill (user role)
  - `POST /api/v1/skills/:id/versions` -- create new version (user role)
  - `GET /api/v1/skills/:id/versions` -- list versions (agent+ role)
  - `GET /api/v1/skills/:id/versions/:version` -- get specific version (agent+ role)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Skills
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user] when action in [:create, :update, :delete, :create_version, :import_skills]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:index, :show, :list_versions, :get_version, :stats, :version_results]

  tags(["Skills"])

  operation(:create,
    summary: "Create skill",
    description: "Creates a skill with v1. Requires user role.",
    request_body:
      {"Skill params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:name, :prompt_text],
         properties: %{
           name: %OpenApiSpex.Schema{type: :string},
           description: %OpenApiSpex.Schema{type: :string, nullable: true},
           prompt_text: %OpenApiSpex.Schema{type: :string},
           project_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 => {"Skill created", "application/json", Schemas.SkillResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:index,
    summary: "List skills",
    description: "Lists skills with pagination and filtering.",
    parameters: [
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"],
      project_id: [in: :query, type: :string, description: "Filter by project"],
      status: [in: :query, type: :string, description: "Filter by status"],
      name: [in: :query, type: :string, description: "Filter by name pattern"]
    ],
    responses: %{
      200 =>
        {"Skill list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.SkillResponse},
             meta: Schemas.PaginationMeta
           }
         }}
    }
  )

  operation(:show,
    summary: "Get skill",
    description: "Returns skill detail with current version prompt.",
    parameters: [id: [in: :path, type: :string, description: "Skill UUID"]],
    responses: %{
      200 => {"Skill detail", "application/json", Schemas.SkillResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:update,
    summary: "Update skill metadata",
    description: "Updates skill description, status, or metadata.",
    parameters: [id: [in: :path, type: :string, description: "Skill UUID"]],
    request_body:
      {"Update params", "application/json",
       %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
    responses: %{
      200 => {"Updated skill", "application/json", Schemas.SkillResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:delete,
    summary: "Archive skill",
    description: "Archives a skill (soft delete).",
    parameters: [id: [in: :path, type: :string, description: "Skill UUID"]],
    responses: %{
      200 => {"Archived skill", "application/json", Schemas.SkillResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:create_version,
    summary: "Create skill version",
    description: "Creates a new version of a skill with updated prompt text.",
    parameters: [id: [in: :path, type: :string, description: "Skill UUID"]],
    request_body:
      {"Version params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:prompt_text],
         properties: %{
           prompt_text: %OpenApiSpex.Schema{type: :string},
           changelog: %OpenApiSpex.Schema{type: :string, nullable: true},
           created_by: %OpenApiSpex.Schema{type: :string, nullable: true}
         }
       }},
    responses: %{
      201 => {"Version created", "application/json", Schemas.SkillVersionResponse},
      404 => {"Skill not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:list_versions,
    summary: "List skill versions",
    description: "Lists all versions of a skill.",
    parameters: [id: [in: :path, type: :string, description: "Skill UUID"]],
    responses: %{
      200 =>
        {"Version list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.SkillVersionResponse}
           }
         }},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:get_version,
    summary: "Get skill version",
    description: "Returns a specific version of a skill.",
    parameters: [
      id: [in: :path, type: :string, description: "Skill UUID"],
      version: [in: :path, type: :integer, description: "Version number"]
    ],
    responses: %{
      200 => {"Version detail", "application/json", Schemas.SkillVersionResponse},
      400 => {"Invalid version", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:import_skills,
    summary: "Import skills",
    description: "Bulk import skills from an array.",
    request_body:
      {"Import params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:skills],
         properties: %{
           skills: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
           }
         }
       }},
    responses: %{
      200 =>
        {"Import summary", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:stats,
    summary: "Get skill stats",
    description: "Returns performance statistics for a skill.",
    parameters: [id: [in: :path, type: :string, description: "Skill UUID"]],
    responses: %{
      200 =>
        {"Skill stats", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:version_results,
    summary: "Get version results",
    description: "Returns skill results for a specific version.",
    parameters: [
      id: [in: :path, type: :string, description: "Skill UUID"],
      version: [in: :path, type: :integer, description: "Version number"]
    ],
    responses: %{
      200 =>
        {"Version results", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Invalid version", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/skills"
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    case Skills.create_skill(tenant_id, params, audit_opts) do
      {:ok, %{skill: skill, version: version}} ->
        conn
        |> put_status(:created)
        |> json(%{skill: skill_json(skill), version: version_json(version)})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc "GET /api/v1/skills"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts = [
      page: parse_int(params["page"]),
      page_size: parse_int(params["page_size"]),
      project_id: params["project_id"],
      status: params["status"],
      name_pattern: params["name"]
    ]

    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    {:ok, result} = Skills.list_skills(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &skill_json/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc "GET /api/v1/skills/:id"
  def show(conn, %{"id" => skill_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Skills.get_skill(tenant_id, skill_id) do
      {:ok, skill} ->
        # Load current version prompt_text
        case Skills.get_version(tenant_id, skill_id, skill.current_version) do
          {:ok, version} ->
            json(conn, %{skill: skill_json(skill), current_prompt: version.prompt_text})

          {:error, :not_found} ->
            json(conn, %{skill: skill_json(skill)})
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "PATCH /api/v1/skills/:id"
  def update(conn, %{"id" => skill_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    attrs =
      params
      |> Map.take(["description", "status", "metadata"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Skills.update_skill(tenant_id, skill_id, attrs, audit_opts) do
      {:ok, skill} -> json(conn, %{skill: skill_json(skill)})
      {:error, :not_found} -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc "DELETE /api/v1/skills/:id"
  def delete(conn, %{"id" => skill_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    case Skills.archive_skill(tenant_id, skill_id, audit_opts) do
      {:ok, skill} -> json(conn, %{skill: skill_json(skill)})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "POST /api/v1/skills/:id/versions"
  def create_version(conn, %{"id" => skill_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    attrs = Map.take(params, ["prompt_text", "changelog", "created_by"])

    case Skills.create_version(tenant_id, skill_id, attrs, audit_opts) do
      {:ok, %{skill: skill, version: version}} ->
        conn
        |> put_status(:created)
        |> json(%{skill: skill_json(skill), version: version_json(version)})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc "GET /api/v1/skills/:id/versions"
  def list_versions(conn, %{"id" => skill_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Skills.list_versions(tenant_id, skill_id) do
      {:ok, versions} ->
        json(conn, %{data: Enum.map(versions, &version_summary_json/1)})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "GET /api/v1/skills/:id/versions/:version"
  def get_version(conn, %{"id" => skill_id, "version" => version_str}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case parse_int(version_str) do
      nil ->
        {:error, :bad_request, "Invalid version number"}

      version_num ->
        case Skills.get_version(tenant_id, skill_id, version_num) do
          {:ok, version} -> json(conn, %{version: version_json(version)})
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc "POST /api/v1/skills/import"
  def import_skills(conn, %{"skills" => skills_data}) when is_list(skills_data) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    {:ok, summary} = Skills.import_skills(tenant_id, skills_data, audit_opts)
    json(conn, summary)
  end

  def import_skills(_conn, _params) do
    {:error, :bad_request, "Request body must contain a 'skills' array"}
  end

  @doc "GET /api/v1/skills/:id/stats"
  def stats(conn, %{"id" => skill_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Skills.skill_stats(tenant_id, skill_id) do
      {:ok, stats} -> json(conn, %{data: stats})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "GET /api/v1/skills/:id/versions/:version/results"
  def version_results(conn, %{"id" => skill_id, "version" => version_str}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case parse_int(version_str) do
      nil ->
        {:error, :bad_request, "Invalid version number"}

      version_num ->
        case Skills.list_version_results(tenant_id, skill_id, version_num) do
          {:ok, results} -> json(conn, %{data: Enum.map(results, &result_json/1)})
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  # --- Private helpers ---

  defp skill_json(skill) do
    %{
      id: skill.id,
      name: skill.name,
      description: skill.description,
      current_version: skill.current_version,
      status: skill.status,
      project_id: skill.project_id,
      metadata: skill.metadata,
      inserted_at: skill.inserted_at,
      updated_at: skill.updated_at
    }
  end

  defp version_json(version) do
    %{
      id: version.id,
      skill_id: version.skill_id,
      version: version.version,
      prompt_text: version.prompt_text,
      changelog: version.changelog,
      created_by: version.created_by,
      metadata: version.metadata,
      inserted_at: version.inserted_at
    }
  end

  defp version_summary_json(version) do
    %{
      id: version.id,
      version: version.version,
      changelog: version.changelog,
      created_by: version.created_by,
      inserted_at: version.inserted_at
    }
  end

  defp result_json(result) do
    %{
      id: result.id,
      skill_version_id: result.skill_version_id,
      verification_result_id: result.verification_result_id,
      story_id: result.story_id,
      metrics: result.metrics,
      inserted_at: result.inserted_at
    }
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp ceil_div(total, page_size), do: div(total + page_size - 1, page_size)
end
