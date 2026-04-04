defmodule LoopctlWeb.TokenUsageController do
  @moduledoc """
  Controller for token usage reporting.

  - `POST /api/v1/token-usage` -- create a standalone token usage report (agent+)
  - `GET /api/v1/stories/:story_id/token-usage` -- list reports for a story (agent+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Formatting
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:create, :index]

  tags(["Token Usage"])

  operation(:create,
    summary: "Create token usage report",
    description:
      "Creates a standalone token usage report for a story without triggering a status transition.",
    request_body:
      {"Token usage params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:story_id, :input_tokens, :output_tokens, :model_name, :cost_millicents],
         properties: %{
           story_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           input_tokens: %OpenApiSpex.Schema{type: :integer, minimum: 0},
           output_tokens: %OpenApiSpex.Schema{type: :integer, minimum: 0},
           model_name: %OpenApiSpex.Schema{type: :string, minLength: 1},
           cost_millicents: %OpenApiSpex.Schema{type: :integer, minimum: 0},
           phase: %OpenApiSpex.Schema{
             type: :string,
             enum: ["planning", "implementing", "reviewing", "other"]
           },
           session_id: %OpenApiSpex.Schema{type: :string, nullable: true},
           skill_version_id: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             nullable: true
           },
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 =>
        {"Report created", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Story not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List token usage reports for a story",
    description:
      "Returns all token usage reports for a story, ordered by inserted_at descending. Includes totals.",
    parameters: [
      story_id: [in: :path, type: :string, description: "Story UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Token usage list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
             },
             totals: %OpenApiSpex.Schema{type: :object, additionalProperties: true},
             meta: Schemas.PaginationMeta
           }
         }},
      404 => {"Story not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/token-usage

  Creates a standalone token usage report for a story. The agent_id is set from
  the authenticated API key. The project_id is derived from the story's epic.
  """
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    story_id = params["story_id"]

    with {:ok, _} <- require_agent_id(api_key.agent_id),
         {:ok, story_id} <- require_story_id(story_id),
         {:ok, story} <- Stories.get_story(tenant_id, story_id) do
      do_create(conn, tenant_id, api_key, story, params)
    end
  end

  defp do_create(conn, tenant_id, api_key, story, params) do
    audit_opts = AuditContext.from_conn(conn)

    attrs =
      params
      |> Map.put("agent_id", api_key.agent_id)
      |> Map.put("project_id", story.project_id)

    case TokenUsage.create_report(tenant_id, attrs, audit_opts) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(%{token_usage_report: format_report(report)})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, :unprocessable_entity, message} ->
        {:error, :unprocessable_entity, message}
    end
  end

  @doc """
  GET /api/v1/stories/:story_id/token-usage

  Lists all token usage reports for a story with pagination and totals.
  """
  def index(conn, %{"story_id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _story} <- Stories.get_story(tenant_id, story_id) do
      opts =
        []
        |> maybe_add_opt(:page, parse_int(params["page"]))
        |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

      {:ok, result} = TokenUsage.list_reports_for_story(tenant_id, story_id, opts)
      {:ok, totals} = TokenUsage.get_story_totals(tenant_id, story_id)

      json(conn, %{
        data: Enum.map(result.data, &format_report/1),
        totals: format_totals(totals),
        meta: %{
          page: result.page,
          page_size: result.page_size,
          total_count: result.total,
          total_pages: ceil_div(result.total, result.page_size)
        }
      })
    end
  end

  # --- Private helpers ---

  defp format_report(report) do
    %{
      id: report.id,
      tenant_id: report.tenant_id,
      story_id: report.story_id,
      agent_id: report.agent_id,
      project_id: report.project_id,
      input_tokens: report.input_tokens,
      output_tokens: report.output_tokens,
      total_tokens: report.total_tokens,
      model_name: report.model_name,
      cost_millicents: report.cost_millicents,
      cost_dollars: Formatting.millicents_to_dollars(report.cost_millicents),
      phase: report.phase,
      session_id: report.session_id,
      skill_version_id: report.skill_version_id,
      metadata: report.metadata,
      inserted_at: report.inserted_at,
      updated_at: report.updated_at
    }
  end

  defp format_totals(totals) do
    %{
      total_input_tokens: totals.total_input_tokens,
      total_output_tokens: totals.total_output_tokens,
      total_tokens: totals.total_tokens,
      total_cost_millicents: totals.total_cost_millicents,
      total_cost_dollars: Formatting.millicents_to_dollars(totals.total_cost_millicents),
      report_count: totals.report_count
    }
  end

  defp require_agent_id(nil),
    do:
      {:error, :unprocessable_entity,
       "API key must be associated with an agent to report token usage"}

  defp require_agent_id(agent_id), do: {:ok, agent_id}

  defp require_story_id(nil), do: {:error, :unprocessable_entity, "story_id is required"}
  defp require_story_id(story_id), do: {:ok, story_id}

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
