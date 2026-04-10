defmodule LoopctlWeb.KnowledgeIngestionController do
  @moduledoc """
  Controller for content ingestion endpoints.

  - `POST /api/v1/knowledge/ingest` -- submit content for knowledge extraction (orchestrator+)
  - `GET /api/v1/knowledge/ingestion-jobs` -- list recent ingestion jobs (orchestrator+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Workers.ContentIngestionWorker

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Wiki"])

  operation(:create,
    summary: "Ingest content for knowledge extraction",
    description:
      "Submit a URL or raw content for knowledge extraction. " <>
        "Enqueues an Oban job that fetches the content (if URL), extracts knowledge " <>
        "articles via LLM, and inserts them as drafts. Role: orchestrator+.",
    request_body:
      {"Ingestion request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           url: %OpenApiSpex.Schema{
             type: :string,
             description: "URL to fetch content from (exactly one of url or content required)"
           },
           content: %OpenApiSpex.Schema{
             type: :string,
             description: "Raw content to extract from (exactly one of url or content required)"
           },
           source_type: %OpenApiSpex.Schema{
             type: :string,
             description:
               "Source type (e.g., newsletter, skill, web_article, ingestion). Required."
           },
           project_id: %OpenApiSpex.Schema{
             type: :string,
             description: "Optional project UUID to scope extracted articles"
           },
           metadata: %OpenApiSpex.Schema{
             type: :object,
             description: "Optional metadata map"
           }
         },
         required: ["source_type"]
       }},
    responses: %{
      202 =>
        {"Ingestion job queued", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 id: %OpenApiSpex.Schema{type: :integer},
                 status: %OpenApiSpex.Schema{type: :string},
                 content_hash: %OpenApiSpex.Schema{type: :string},
                 source_type: %OpenApiSpex.Schema{type: :string},
                 inserted_at: %OpenApiSpex.Schema{type: :string}
               }
             }
           }
         }},
      200 =>
        {"Already queued", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 status: %OpenApiSpex.Schema{type: :string},
                 content_hash: %OpenApiSpex.Schema{type: :string}
               }
             }
           }
         }},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/knowledge/ingest"
  def create(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    url = params["url"]
    content = params["content"]
    source_type = params["source_type"]
    project_id = params["project_id"]
    metadata = params["metadata"]

    with :ok <- validate_content_source(url, content),
         :ok <- validate_source_type(source_type) do
      content_hash = compute_content_hash(url || content)

      job_args =
        %{
          "tenant_id" => tenant_id,
          "content_hash" => content_hash,
          "source_type" => source_type
        }
        |> maybe_put("url", url)
        |> maybe_put("content", content)
        |> maybe_put("project_id", project_id)
        |> maybe_put("metadata", metadata)

      case ContentIngestionWorker.new(job_args) |> Oban.insert() do
        {:ok, %Oban.Job{conflict?: true} = job} ->
          conn
          |> put_status(200)
          |> json(
            LoopctlWeb.KnowledgeIngestionJSON.already_queued(%{
              content_hash: content_hash,
              job: job
            })
          )

        {:ok, job} ->
          conn
          |> put_status(202)
          |> json(
            LoopctlWeb.KnowledgeIngestionJSON.queued(%{
              job: job,
              content_hash: content_hash,
              source_type: source_type
            })
          )

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  operation(:index,
    summary: "List recent ingestion jobs",
    description:
      "Returns recent content ingestion jobs for the current tenant. " <>
        "Limited to last 7 days, max 50 results. Role: orchestrator+.",
    responses: %{
      200 =>
        {"Ingestion jobs list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "List of recent ingestion jobs"
             }
           }
         }},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/ingestion-jobs"
  def index(conn, _params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    jobs = list_ingestion_jobs(tenant_id)

    json(conn, LoopctlWeb.KnowledgeIngestionJSON.index(jobs))
  end

  # --- Private ---

  defp validate_content_source(nil, nil) do
    {:error, :unprocessable_entity, "Exactly one of 'url' or 'content' is required"}
  end

  defp validate_content_source(url, content) when is_binary(url) and is_binary(content) do
    {:error, :unprocessable_entity, "Provide exactly one of 'url' or 'content', not both"}
  end

  defp validate_content_source("", nil) do
    {:error, :unprocessable_entity, "Exactly one of 'url' or 'content' is required"}
  end

  defp validate_content_source(nil, "") do
    {:error, :unprocessable_entity, "Exactly one of 'url' or 'content' is required"}
  end

  defp validate_content_source(_url, nil), do: :ok
  defp validate_content_source(nil, _content), do: :ok

  defp validate_source_type(nil) do
    {:error, :unprocessable_entity, "'source_type' is required"}
  end

  defp validate_source_type(""), do: {:error, :unprocessable_entity, "'source_type' is required"}
  defp validate_source_type(_), do: :ok

  defp compute_content_hash(input) when is_binary(input) do
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp list_ingestion_jobs(tenant_id) do
    import Ecto.Query

    tenant_id_str = tenant_id

    seven_days_ago = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)

    from(j in "oban_jobs",
      where:
        fragment("? = 'Loopctl.Workers.ContentIngestionWorker'", j.worker) and
          fragment("?->>'tenant_id' = ?", j.args, ^tenant_id_str) and
          j.inserted_at > ^seven_days_ago,
      order_by: [desc: j.inserted_at],
      limit: 50,
      select: %{
        id: j.id,
        state: j.state,
        args: j.args,
        inserted_at: j.inserted_at,
        completed_at: j.completed_at,
        errors: j.errors
      }
    )
    |> Loopctl.Repo.all()
  end
end
