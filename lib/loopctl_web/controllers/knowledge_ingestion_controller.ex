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

    case enqueue_item(tenant_id, params) do
      {:ok, :queued, %{job: job, content_hash: content_hash, source_type: source_type}} ->
        conn
        |> put_status(202)
        |> json(
          LoopctlWeb.KnowledgeIngestionJSON.queued(%{
            job: job,
            content_hash: content_hash,
            source_type: source_type
          })
        )

      {:ok, :already_queued, %{job: job, content_hash: content_hash}} ->
        conn
        |> put_status(200)
        |> json(
          LoopctlWeb.KnowledgeIngestionJSON.already_queued(%{
            content_hash: content_hash,
            job: job
          })
        )

      # Pass validation / changeset errors through to the FallbackController
      # which renders 4xx responses with the provided message.
      {:error, _status, _message} = err ->
        err

      {:error, %Ecto.Changeset{}} = err ->
        err
    end
  end

  operation(:create_batch,
    summary: "Batch ingest content for knowledge extraction",
    description:
      "Submit multiple URLs or raw content items for knowledge extraction in a single " <>
        "request. Each item is validated and enqueued independently. " <>
        "Max 50 items per batch. Role: orchestrator+.",
    request_body:
      {"Batch ingestion request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           items: %OpenApiSpex.Schema{
             type: :array,
             description:
               "Array of ingestion items (max 50). Each item has the same shape as " <>
                 "POST /knowledge/ingest: url or content, source_type (required), " <>
                 "project_id (optional), metadata (optional).",
             maxItems: 50
           }
         },
         required: ["items"]
       }},
    responses: %{
      200 =>
        {"Batch ingestion results", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Per-item results, one entry per submitted item."
             }
           }
         }},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/knowledge/ingest/batch"
  def create_batch(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    items = params["items"]

    with :ok <- validate_batch_items(items) do
      results = Enum.map(items, &enqueue_item_result(tenant_id, &1))
      json(conn, LoopctlWeb.KnowledgeIngestionJSON.batch(results))
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

  # Max batch size for POST /knowledge/ingest/batch
  @batch_max 50

  defp validate_batch_items(items) when is_list(items) and items != [] do
    if length(items) > @batch_max do
      {:error, :unprocessable_entity,
       "Batch exceeds max of #{@batch_max} items (got #{length(items)})"}
    else
      :ok
    end
  end

  defp validate_batch_items([]) do
    {:error, :unprocessable_entity, "'items' must be a non-empty array"}
  end

  defp validate_batch_items(_) do
    {:error, :unprocessable_entity, "'items' must be a non-empty array"}
  end

  # Enqueue a single item and return {:ok, :queued | :already_queued, map} or
  # {:error, ...}. Used by both single-item create/2 and batch create_batch/2.
  defp enqueue_item(tenant_id, params) do
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
          {:ok, :already_queued, %{job: job, content_hash: content_hash}}

        {:ok, job} ->
          {:ok, :queued, %{job: job, content_hash: content_hash, source_type: source_type}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # Wrap enqueue_item/2 to always return a per-item result map for batch mode.
  # Batch mode never fails the whole request for a single invalid item — every
  # item gets a result entry so the caller sees exactly what happened.
  defp enqueue_item_result(tenant_id, params) when is_map(params) do
    case enqueue_item(tenant_id, params) do
      {:ok, :queued, %{job: job, content_hash: content_hash, source_type: source_type}} ->
        %{
          status: "queued",
          id: job.id,
          content_hash: content_hash,
          source_type: source_type,
          inserted_at: job.inserted_at
        }

      {:ok, :already_queued, %{job: job, content_hash: content_hash}} ->
        %{
          status: "already_queued",
          id: job.id,
          content_hash: content_hash
        }

      {:error, :unprocessable_entity, message} ->
        %{status: "error", error: message}

      {:error, %Ecto.Changeset{} = changeset} ->
        %{status: "error", error: format_changeset_errors(changeset)}

      {:error, other} ->
        %{status: "error", error: inspect(other)}
    end
  end

  defp enqueue_item_result(_tenant_id, _params) do
    %{status: "error", error: "item must be an object"}
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

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
