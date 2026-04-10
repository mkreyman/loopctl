defmodule LoopctlWeb.KnowledgePipelineController do
  @moduledoc """
  Controller for the knowledge pipeline status endpoint.

  - `GET /api/v1/knowledge/pipeline` -- pipeline status (orchestrator+)

  Returns metrics about the self-learning knowledge extraction pipeline:
  pending extractions, recent drafts, publish rate, extraction errors,
  and the auto_extract setting.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Wiki"])

  operation(:status,
    summary: "Knowledge pipeline status",
    description:
      "Returns metrics about the self-learning knowledge extraction pipeline " <>
        "including pending extractions, recent drafts, publish rate, extraction " <>
        "errors, and the auto_extract_enabled setting. Role: orchestrator+.",
    responses: %{
      200 =>
        {"Pipeline status", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 pending_extractions: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Count of pending ReviewKnowledgeWorker jobs"
                 },
                 recent_drafts: %OpenApiSpex.Schema{
                   type: :array,
                   description: "20 most recent draft articles from review findings"
                 },
                 publish_rate: %OpenApiSpex.Schema{
                   type: :number,
                   description: "Ratio of published to total review_finding articles (0.0-1.0)"
                 },
                 extraction_errors: %OpenApiSpex.Schema{
                   type: :object,
                   properties: %{
                     count: %OpenApiSpex.Schema{type: :integer},
                     recent: %OpenApiSpex.Schema{type: :array}
                   }
                 },
                 auto_extract_enabled: %OpenApiSpex.Schema{
                   type: :boolean,
                   description: "Whether automatic knowledge extraction is enabled"
                 }
               }
             }
           }
         }},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/pipeline"
  def status(conn, _params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    {:ok, result} = Knowledge.pipeline_status(tenant_id)
    json(conn, LoopctlWeb.KnowledgePipelineJSON.status(result))
  end
end
