defmodule LoopctlWeb.KnowledgeIngestionController do
  @moduledoc """
  Controller for content ingestion endpoints.

  - `POST /api/v1/knowledge/ingest` -- submit content for knowledge extraction (orchestrator+)
  - `GET /api/v1/knowledge/ingestion-jobs` -- list recent ingestion jobs (orchestrator+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.HeavyRead
  alias Loopctl.Llm
  alias Loopctl.Net.UrlGuard
  alias Loopctl.Oban.FairShare
  alias Loopctl.ObanConfig
  alias Loopctl.Workers.ContentIngestionWorker

  # Mandatory BYO (Epic 28, #179): extraction runs on the tenant's OWN Anthropic
  # key. Reject up front with a clear 422 so we never enqueue a job that can only
  # {:discard} for a missing key.
  @no_api_key_message "Configure your Anthropic API key before ingesting content. " <>
                        "loopctl is BYO — provision it ONCE via the set_llm_config MCP tool " <>
                        "(user role), or PATCH /api/v1/tenants/me/llm-config. See the response " <>
                        "`remediation` for the exact call."
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.ProjectId

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Wiki"])

  operation(:create,
    summary: "Ingest content for knowledge extraction",
    description:
      "Submit a URL or raw content for knowledge extraction. " <>
        "Enqueues an Oban job that fetches the content (if URL), extracts knowledge " <>
        "articles via LLM, and inserts them. Extracted articles are created as " <>
        "**drafts by default** (lower-trust LLM output, staged for review) — unlike " <>
        "direct POST /articles which publishes by default. Pass `publish: true` to " <>
        "publish them on extraction instead. Role: orchestrator+.",
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
           publish: %OpenApiSpex.Schema{
             type: :boolean,
             description:
               "Publish extracted articles immediately instead of staging them as " <>
                 "drafts. Default false (draft)."
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

    with :ok <- require_llm_key(tenant_id) do
      handle_create(conn, tenant_id, params)
    end
  end

  defp handle_create(conn, tenant_id, params) do
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
        "Max 50 items per batch. Role: orchestrator+.\n\n" <>
        "**Backpressure (429):** before enqueuing anything, the endpoint checks the " <>
        "calling tenant's in-flight `:ingestion` backlog. If it is at/over the " <>
        "`OBAN_INGEST_BACKLOG_MAX` threshold, the WHOLE request is rejected " <>
        "all-or-nothing with 429 + `Retry-After` and `error.code: " <>
        "\"ingestion_backlog_exceeded\"` — zero jobs are enqueued. This is distinct " <>
        "from the generic Hammer request-rate 429 (which has no `error.code`).",
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
                 "project_id (optional), publish (optional, default false → draft), " <>
                 "metadata (optional).",
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
      429 =>
        {"Too Many Requests — one of two DISTINCT 429s this route can return: (1) " <>
           "US-36.3 ingestion-backlog backpressure (`error.code: " <>
           "\"ingestion_backlog_exceeded\"`, sets `Retry-After`), or (2) the generic " <>
           "shared Hammer request-rate limiter (NO `error.code`; `error.message: " <>
           "\"Rate limit exceeded\"`). Branch on the presence of `error.code`.",
         "application/json",
         %OpenApiSpex.Schema{
           oneOf: [Schemas.IngestionBacklogError, Schemas.RateLimitError]
         }}
    }
  )

  @doc "POST /api/v1/knowledge/ingest/batch"
  def create_batch(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    items = params["items"]

    # The backlog gate runs AFTER validate_batch_items/1 (so a malformed request still
    # 422s first) but BEFORE process_batch_items/3 (so when the tenant is over its
    # in-flight :ingestion backlog threshold, ZERO jobs from this request are enqueued —
    # all-or-nothing, no partial pile-up). US-36.3.
    with :ok <- require_llm_key(tenant_id),
         :ok <- validate_batch_items(items),
         :ok <- check_ingestion_backlog(tenant_id) do
      results = process_batch_items(tenant_id, items)
      json(conn, LoopctlWeb.KnowledgeIngestionJSON.batch(results))
    end
  end

  # US-36.3 admission gate: reject the WHOLE batch with 429 when the calling tenant's
  # in-flight :ingestion backlog is at/over the env-driven threshold, BEFORE enqueuing
  # anything. Reuses the US-36.2 broad non-terminal count helper (tenant-scoped by
  # args->>'tenant_id', bounded by a per-query statement_timeout via AdminRepo) — cheap
  # and scoped to the caller ONLY, so one tenant's backlog never affects another. The
  # error tuple is rendered by LoopctlWeb.FallbackController (structured 429 + Retry-After,
  # code "ingestion_backlog_exceeded" — distinct from the Hammer request-rate 429).
  defp check_ingestion_backlog(tenant_id) do
    max = ObanConfig.ingest_backlog_max()

    if in_flight_ingestion_backlog(tenant_id) >= max do
      {:error, :ingestion_backlog_exceeded, backlog_retry_after_seconds()}
    else
      :ok
    end
  end

  # FAIL OPEN, mirroring the US-36.2 fair-share gate (`Loopctl.Oban.FairShare.over_cap?/4`):
  # an unmeasurable backlog count must NEVER block work. The reused count runs under a 2s
  # `SET LOCAL statement_timeout` and — per FairShare's cost model — scans every
  # non-terminal `:ingestion` row FLEET-WIDE (tenant is a post-Filter), so during the
  # deep-queue flood this feature targets it is MOST likely to hit that bound. A raised
  # statement_timeout / transient Postgrex/DBConnection error must therefore not escape
  # here as a generic HTTP 500 that rejects an innocent, under-threshold tenant's batch;
  # instead we log and admit (return 0 → below any positive threshold). The count is
  # resolved through a config-swappable DI seam (`Loopctl.Oban.FairShare` in prod, a Mox
  # mock in test) so this fail-open path is deterministically covered.
  defp in_flight_ingestion_backlog(tenant_id) do
    backlog_counter().in_flight_count(tenant_id, :ingestion)
  rescue
    e ->
      Logger.warning(
        "ingestion backlog gate failed open for tenant=#{tenant_id}: " <>
          Exception.message(e)
      )

      0
  end

  defp backlog_counter do
    Application.get_env(:loopctl, :ingestion_backlog_counter, FairShare)
  end

  # Retry-After hint (seconds) for a backlog-429. Tied to the fair-share snooze base so
  # it tracks the drain cadence of the :ingestion queue: a snoozed/backlogged job
  # re-checks on roughly this horizon, so advising the client to wait the same amount
  # before retrying is a sensible, bounded, deploy-free-tunable value. Bounded to a
  # small positive integer of seconds.
  defp backlog_retry_after_seconds do
    ObanConfig.fair_share_snooze_base_seconds()
  end

  # Mandatory BYO gate shared by single + batch ingest. On a miss, record the block
  # (log + telemetry + audit, review #2) and return a coded 422.
  defp require_llm_key(tenant_id) do
    if Llm.has_api_key?(tenant_id) do
      :ok
    else
      Llm.record_blocked(tenant_id, :extraction)
      {:error, :no_api_key_configured, @no_api_key_message}
    end
  end

  # Bound the aggregate request time (worker-01 / GHSA-j7m9-ffmr-pwhm). Each item
  # does bounded per-item DNS validation (A+AAAA), but a serial Enum.map over up
  # to @batch_max (50) items could still tie up a web worker for minutes on
  # unresponsive nameservers. async_stream caps concurrency AND imposes a per-item
  # wall-clock deadline; a hung item is killed and mapped to a validation_timeout
  # error, so the whole request is bounded regardless of any single hanging item.
  # Ordering + per-item result shape are preserved.
  #
  # We use the NOLINK Task.Supervisor variant (monitors, not links) so a genuine
  # (non-timeout) raise in one item — e.g. an Oban.insert pool checkout-timeout
  # under the 10-way intra-request concurrency — is caught and returned as a
  # per-item {:exit, reason} error instead of killing the whole request (Bandit's
  # HTTP/2 stream process does not trap exits). This preserves the "one bad item
  # never fails the whole batch" invariant.
  #
  # tenant_id is passed explicitly into each task (no process-dict/RLS state is
  # relied on); Ecto Sandbox + Mox resolve via the `$callers` chain that
  # Task.Supervisor.async_stream_nolink propagates.
  defp process_batch_items(tenant_id, items) do
    Loopctl.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      items,
      fn item -> enqueue_item_result(tenant_id, item) end,
      max_concurrency: 10,
      timeout: batch_item_timeout_ms(),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, :timeout} ->
        Logger.warning("batch item validation timeout")
        %{status: "error", error: "validation_timeout"}

      {:exit, reason} ->
        Logger.warning("batch item validation crashed: #{inspect(reason)}")
        %{status: "error", error: "validation_failed"}
    end)
  end

  # Per-item wall-clock deadline for batch validation. Config-based DI so the
  # timeout path is testable deterministically without a multi-second wait.
  @default_batch_item_timeout_ms 5_000
  defp batch_item_timeout_ms do
    Application.get_env(
      :loopctl,
      :batch_item_validation_timeout_ms,
      @default_batch_item_timeout_ms
    )
  end

  operation(:index,
    summary: "List ingestion jobs",
    description:
      "Returns content ingestion jobs for the current tenant, newest first, with " <>
        "offset/limit pagination over the full history (advance `offset` by " <>
        "`meta.limit` to enumerate to completeness). Optional `since_days` narrows " <>
        "to a recent window. Role: orchestrator+.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        description: "Max jobs per page (default 20). A larger value is clamped, never rejected.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Rows to skip (default 0)",
        required: false
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Optional: only jobs from the last N days (default: all history)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Ingestion jobs list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Page of ingestion jobs"
             },
             meta: Schemas.PaginationMeta
           }
         }},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/ingestion-jobs"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    {:ok, limit} = Pagination.validate_limit(params)
    offset = parse_offset(params["offset"])
    since = parse_since_days(params["since_days"])

    %{data: jobs, meta: meta} =
      list_ingestion_jobs(tenant_id, limit: limit, offset: offset, since: since)

    json(conn, LoopctlWeb.KnowledgeIngestionJSON.index(jobs, meta))
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
    # Normalize "" -> nil (absent) so a blank project_id never becomes a truthy
    # job arg that the worker would try to dump against the :binary_id column.
    project_id = blank_to_nil(params["project_id"])
    metadata = params["metadata"]
    # Ingested (LLM-extracted) articles stay DRAFT by default — they're
    # lower-trust and meant for review. Opt in with publish: true to have the
    # worker create them published (mirrors create-time publish, but off by
    # default for ingest). Only true/"true" enables it; anything else is draft.
    publish = params["publish"] == true or params["publish"] == "true"

    # Validate project_id at the boundary so a malformed / non-string value is a
    # clean 422 (or per-item batch error) and NEVER becomes a queued job — a job
    # carrying a non-UUID project_id would crash the worker on Ecto dump and, since
    # the uniqueness key excludes project_id, crash-loop as a poison pill.
    with :ok <- validate_ingest_project_id(project_id),
         :ok <- validate_content_source(url, content),
         :ok <- validate_source_type(source_type),
         :ok <- validate_url_egress(url) do
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
        |> maybe_put("publish", if(publish, do: true))

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

  # Ingestion is a WRITE path: a non-UUID project_id becomes a poison-pill job, so
  # be strict — nil/"" is absent (:ok), a valid UUID is :ok, and anything else
  # (malformed string OR a non-string list/map from a JSON array/object body) is a
  # 422. Unlike the read-path helper, non-strings are rejected here rather than
  # tolerated, since they would still enqueue a crashing job.
  defp validate_ingest_project_id(value) when is_nil(value) or is_binary(value) do
    ProjectId.validate(value)
  end

  defp validate_ingest_project_id(_non_string) do
    {:error, :unprocessable_entity, "Invalid project_id: must be a valid UUID"}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp validate_source_type(nil) do
    {:error, :unprocessable_entity, "'source_type' is required"}
  end

  defp validate_source_type(""), do: {:error, :unprocessable_entity, "'source_type' is required"}
  defp validate_source_type(_), do: :ok

  # SSRF egress guard (worker-01 / GHSA-j7m9-ffmr-pwhm). Reject a URL that points
  # at a private / loopback / link-local / cloud-metadata address up front (4xx)
  # so a bad URL never reaches the worker. Content-only ingests (url == nil) skip
  # this. The worker re-validates before fetching to defend against DNS rebinding.
  defp validate_url_egress(nil), do: :ok

  defp validate_url_egress(url) when is_binary(url) do
    case UrlGuard.validate_egress(url) do
      {:ok, _uri} ->
        :ok

      {:error, :invalid_scheme} ->
        {:error, :unprocessable_entity, "'url' must use the http or https scheme"}

      {:error, :invalid_url} ->
        {:error, :unprocessable_entity, "'url' is not a valid URL"}

      {:error, :missing_host} ->
        {:error, :unprocessable_entity, "'url' must have a valid host"}

      {:error, :dns_resolution_failed} ->
        {:error, :unprocessable_entity, "'url' host could not be resolved"}

      {:error, :blocked_ip} ->
        {:error, :unprocessable_entity,
         "'url' must not target a private, loopback, or metadata address"}
    end
  end

  defp compute_content_hash(input) when is_binary(input) do
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_offset(value) do
    case parse_int_param(value) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  defp parse_since_days(value) do
    case parse_int_param(value) do
      n when is_integer(n) and n > 0 ->
        DateTime.add(DateTime.utc_now(), -n * 86_400, :second)

      _ ->
        nil
    end
  end

  defp parse_int_param(value) when is_integer(value), do: value

  defp parse_int_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int_param(_), do: nil

  # Offset/limit pagination over the tenant's ingestion jobs (newest first), with
  # an `id` tiebreaker so the page is stable across equal timestamps. No hard cap
  # and no fixed time window: a caller paginates to completeness via offset.
  defp list_ingestion_jobs(tenant_id, opts) do
    import Ecto.Query

    limit = Keyword.fetch!(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)
    since = Keyword.get(opts, :since)

    base =
      from(j in "oban_jobs",
        where:
          fragment("? = 'Loopctl.Workers.ContentIngestionWorker'", j.worker) and
            fragment("?->>'tenant_id' = ?", j.args, ^tenant_id)
      )

    base = if since, do: where(base, [j], j.inserted_at > ^since), else: base

    # Route the COUNT + paginated list through HeavyRead so each query runs under a
    # per-read `SET LOCAL statement_timeout` on the dedicated heavy-read pool (US-34.6):
    # a pathological seq-scan COUNT over the ever-growing Oban-owned `oban_jobs` table
    # can't run unbounded on the request path. Mirrors the `Loopctl.Llm` usage-summary
    # pattern (a heavy count + paginated rows over a large table). The `oban_jobs` source
    # is the SCHEMALESS string table `from(j in "oban_jobs")` (schema `nil` → HeavyRead's
    # structural guard classifies it as `:other` and passes WITHOUT a tenant-equality
    # check), and `oban_jobs` carries no RLS policy. So on this BYPASSRLS read path
    # tenant scoping rests ENTIRELY on the `args->>'tenant_id' = ^tenant_id` fragment in
    # `base` — there is no structural or RLS backstop. Do NOT weaken/parameterize that
    # fragment. The regression guard for it is the tenant-isolation test in
    # knowledge_ingestion_controller_test.exs ("tenant isolation" describe), which inserts
    # BOTH tenants' rows directly and asserts the caller sees only its own; keep it green.
    total_query = select(base, [j], count(j.id))
    total = HeavyRead.one(tenant_id, total_query, HeavyRead.opts(:ingestion_jobs)) || 0

    # The ORDER BY matches the trailing columns of the composite partial index
    # oban_jobs_ingestion_tenant_idx ((args->>'tenant_id'), inserted_at DESC, id DESC)
    # WHERE worker = ContentIngestionWorker (migration 20260713020000), so after the
    # equality-matched tenant column the planner answers this ordered page with an ordered
    # Index Scan feeding Limit — NO full Sort, even for a tenant with a large history.
    rows_query =
      base
      |> order_by([j], desc: j.inserted_at, desc: j.id)
      |> limit(^limit)
      |> offset(^offset)
      |> select([j], %{
        id: j.id,
        state: j.state,
        args: j.args,
        inserted_at: j.inserted_at,
        completed_at: j.completed_at,
        errors: j.errors
      })

    rows = HeavyRead.all(tenant_id, rows_query, HeavyRead.opts(:ingestion_jobs))

    %{data: rows, meta: %{limit: limit, offset: offset, total_count: total}}
  end
end
