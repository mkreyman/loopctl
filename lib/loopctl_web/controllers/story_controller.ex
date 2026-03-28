defmodule LoopctlWeb.StoryController do
  @moduledoc """
  Controller for story CRUD operations.

  - `POST /api/v1/epics/:epic_id/stories` -- user role, creates a story
  - `GET /api/v1/epics/:epic_id/stories` -- agent+, lists stories with filters
  - `GET /api/v1/stories/:id` -- agent+, story detail
  - `PATCH /api/v1/stories/:id` -- user role, updates metadata fields
  - `DELETE /api/v1/stories/:id` -- user role, deletes a story
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Artifacts
  alias Loopctl.WorkBreakdown.Dependencies
  alias Loopctl.WorkBreakdown.Epics
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user] when action in [:create, :update, :delete]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:index, :show, :index_by_project]

  tags(["Stories"])

  operation(:create,
    summary: "Create story",
    description: "Creates a new story within an epic. Requires user+ role.",
    parameters: [epic_id: [in: :path, type: :string, description: "Epic UUID"]],
    request_body:
      {"Story params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:number, :title],
         properties: %{
           number: %OpenApiSpex.Schema{type: :string},
           title: %OpenApiSpex.Schema{type: :string},
           description: %OpenApiSpex.Schema{type: :string, nullable: true},
           acceptance_criteria: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :object},
             nullable: true
           },
           estimated_hours: %OpenApiSpex.Schema{type: :number, nullable: true},
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 => {"Story created", "application/json", Schemas.StoryResponse},
      404 => {"Epic not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List stories",
    description: "Lists stories for an epic with pagination and status filtering.",
    parameters: [
      epic_id: [in: :path, type: :string, description: "Epic UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"],
      agent_status: [in: :query, type: :string, description: "Filter by agent status"],
      verified_status: [in: :query, type: :string, description: "Filter by verified status"]
    ],
    responses: %{
      200 =>
        {"Story list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.StoryResponse},
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index_by_project,
    summary: "List stories by project",
    description:
      "Lists all stories for a project. " <>
        "Requires agent+ role. Supports filtering by status and epic. " <>
        "Uses offset-based pagination (limit/offset).",
    parameters: [
      project_id: [in: :query, type: :string, required: true, description: "Project UUID"],
      agent_status: [
        in: :query,
        type: :string,
        description: "Filter by agent status",
        example: "pending"
      ],
      verified_status: [
        in: :query,
        type: :string,
        description: "Filter by verified status",
        example: "unverified"
      ],
      epic_id: [
        in: :query,
        type: :string,
        description: "Filter to a specific epic UUID"
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max stories to return (default 100, max 500)"
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Number of stories to skip (default 0)"
      ]
    ],
    responses: %{
      200 =>
        {"Story list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.StoryResponse},
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 limit: %OpenApiSpex.Schema{type: :integer},
                 offset: %OpenApiSpex.Schema{type: :integer}
               }
             }
           }
         }},
      400 => {"Missing project_id", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:show,
    summary: "Get story",
    description: "Returns a single story with dependencies and artifacts.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Story detail", "application/json", Schemas.StoryResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update story",
    description: "Updates story metadata fields. Cannot update agent_status or verified_status.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Update params", "application/json",
       %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
    responses: %{
      200 => {"Updated story", "application/json", Schemas.StoryResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Delete story",
    description: "Deletes a story. Requires user+ role.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      204 => {"Deleted", "application/json", %OpenApiSpex.Schema{type: :string}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/epics/:epic_id/stories

  Creates a new story. Requires user+ role.
  """
  def create(conn, %{"epic_id" => epic_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _epic} <- Epics.get_epic(tenant_id, epic_id) do
      attrs = %{
        epic_id: epic_id,
        number: params["number"],
        title: params["title"],
        description: params["description"],
        acceptance_criteria: params["acceptance_criteria"],
        estimated_hours: parse_decimal(params["estimated_hours"]),
        metadata: params["metadata"] || %{}
      }

      audit_opts = AuditContext.from_conn(conn)

      case Stories.create_story(tenant_id, attrs, audit_opts) do
        {:ok, story} ->
          conn
          |> put_status(:created)
          |> json(%{story: story_json(story)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/v1/epics/:epic_id/stories

  Lists stories for an epic. Requires agent+ role.
  Supports filtering by ?agent_status=... and ?verified_status=...
  """
  def index(conn, %{"epic_id" => epic_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _epic} <- Epics.get_epic(tenant_id, epic_id) do
      opts =
        []
        |> maybe_add_opt(:agent_status, params["agent_status"])
        |> maybe_add_opt(:verified_status, params["verified_status"])
        |> maybe_add_opt(:page, parse_int(params["page"]))
        |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

      {:ok, result} = Stories.list_stories(tenant_id, epic_id, opts)

      json(conn, %{
        data: Enum.map(result.data, &story_json/1),
        meta: %{
          page: result.page,
          page_size: result.page_size,
          total_count: result.total,
          total_pages: ceil_div(result.total, result.page_size)
        }
      })
    end
  end

  @doc """
  GET /api/v1/stories?project_id=X

  Lists all stories for a project. Requires agent+ role.
  Supports ?agent_status=, ?verified_status=, ?epic_id=, ?limit=, ?offset=
  """
  def index_by_project(conn, %{"project_id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:agent_status, params["agent_status"])
      |> maybe_add_opt(:verified_status, params["verified_status"])
      |> maybe_add_opt(:epic_id, params["epic_id"])
      |> maybe_add_opt(:limit, parse_int(params["limit"]))
      |> maybe_add_opt(:offset, parse_int(params["offset"]))

    {:ok, result} = Stories.list_stories_by_project(tenant_id, project_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &story_json/1),
      meta: %{
        total_count: result.total,
        limit: result.limit,
        offset: result.offset
      }
    })
  end

  def index_by_project(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{status: 400, message: "project_id query parameter is required"}})
  end

  @doc """
  GET /api/v1/stories/:id

  Returns a single story with dependencies and artifacts.
  Requires agent+ role.
  """
  def show(conn, %{"id" => story_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Stories.get_story(tenant_id, story_id) do
      {:ok, story} ->
        {:ok, story_deps} =
          Dependencies.list_story_dependencies_for_epic(tenant_id, story.epic_id)

        # Filter to deps where this story is the dependent
        deps_for_story =
          story_deps
          |> Enum.filter(fn dep -> dep.story_id == story.id end)
          |> Enum.map(fn dep ->
            %{story_id: dep.story_id, depends_on_story_id: dep.depends_on_story_id}
          end)

        # Fetch artifact reports and verification count for this story
        {:ok, artifacts_result} = Artifacts.list_artifact_reports(tenant_id, story.id)
        iteration_count = Artifacts.count_verifications(tenant_id, story.id)

        json(conn, %{
          story:
            story_json(story)
            |> Map.merge(%{
              dependencies: deps_for_story,
              artifacts: artifacts_result.data,
              latest_verification: nil,
              iteration_count: iteration_count
            })
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  PATCH /api/v1/stories/:id

  Updates story metadata fields. Cannot update agent_status or verified_status.
  Requires user+ role.
  """
  def update(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, story} <- Stories.get_story(tenant_id, story_id) do
      attrs = %{
        title: params["title"],
        description: params["description"],
        acceptance_criteria: params["acceptance_criteria"],
        estimated_hours: parse_decimal(params["estimated_hours"]),
        metadata: params["metadata"]
      }

      # Remove nil values so we only update provided fields
      attrs = Map.reject(attrs, fn {_k, v} -> is_nil(v) end)

      audit_opts = AuditContext.from_conn(conn)

      case Stories.update_story(tenant_id, story, attrs, audit_opts) do
        {:ok, updated} ->
          json(conn, %{story: story_json(updated)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  DELETE /api/v1/stories/:id

  Deletes a story. Requires user+ role.
  """
  def delete(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, story} <- Stories.get_story(tenant_id, story_id) do
      audit_opts = AuditContext.from_conn(conn)

      case Stories.delete_story(tenant_id, story, audit_opts) do
        {:ok, _deleted} ->
          send_resp(conn, :no_content, "")

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  # --- Private helpers ---

  defp story_json(story) do
    %{
      id: story.id,
      tenant_id: story.tenant_id,
      project_id: story.project_id,
      epic_id: story.epic_id,
      number: story.number,
      title: story.title,
      description: story.description,
      acceptance_criteria: story.acceptance_criteria,
      estimated_hours: story.estimated_hours,
      agent_status: story.agent_status,
      verified_status: story.verified_status,
      assigned_agent_id: story.assigned_agent_id,
      assigned_at: story.assigned_at,
      reported_done_at: story.reported_done_at,
      verified_at: story.verified_at,
      rejected_at: story.rejected_at,
      rejection_reason: story.rejection_reason,
      sort_key: story.sort_key,
      metadata: story.metadata,
      inserted_at: story.inserted_at,
      updated_at: story.updated_at
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

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_number(val), do: Decimal.new("#{val}")

  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
