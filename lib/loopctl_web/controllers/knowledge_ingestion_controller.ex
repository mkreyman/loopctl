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
  alias Loopctl.Ingestion.ContentEnvelope
  alias Loopctl.Knowledge.ContentChunker
  alias Loopctl.Llm
  alias Loopctl.LocalGuc
  alias Loopctl.Net.UrlGuard
  alias Loopctl.Oban.FairShare
  alias Loopctl.ObanConfig
  alias Loopctl.TelemetryEvents
  alias Loopctl.Workers.ContentIngestionWorker

  # Mandatory BYO (Epic 28, #179): extraction runs on the tenant's OWN Anthropic
  # key. Reject up front with a clear 422 so we never enqueue a job that can only
  # {:discard} for a missing key.
  @no_api_key_message "Configure your Anthropic API key before ingesting content. " <>
                        "loopctl is BYO — provision it ONCE via the set_llm_config MCP tool " <>
                        "(user role), or PATCH /api/v1/tenants/me/llm-config. See the response " <>
                        "`remediation` for the exact call."

  # Inline-content ceiling (#493 review, findings 5/7). Declared HERE, above the
  # `operation/2` specs, so the published OpenAPI `maxLength` and the enforcing
  # `validate_content_length/1` read the SAME number and cannot drift.
  @max_inline_content_bytes 1_000_000
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
        "publish them on extraction instead. Role: orchestrator+.\n\n" <>
        "**At rest:** inline `content` is encrypted (AES-256-GCM) in the job record " <>
        "and is never persisted in the clear. `url`, `source_type`, and `metadata` " <>
        "are NOT encrypted — do not put sensitive values in `metadata`.",
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
             maxLength: @max_inline_content_bytes,
             description:
               "Raw content to extract from (exactly one of url or content required). " <>
                 "Capped at #{@max_inline_content_bytes} bytes — a larger body is rejected " <>
                 "with 422; fetch bigger documents via `url` instead. Encrypted at rest."
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
      429 =>
        {"Too Many Requests — one of two DISTINCT 429s this route can return: (1) " <>
           "US-36.3 ingestion-backlog backpressure (`error.code: " <>
           "\"ingestion_backlog_exceeded\"`, sets `Retry-After`) — the single-item path " <>
           "is gated on the SAME per-tenant backlog threshold as /ingest/batch so it " <>
           "cannot be looped to bypass the valve — or (2) the generic shared Hammer " <>
           "request-rate limiter (NO `error.code`). Branch on the presence of `error.code`.",
         "application/json",
         %OpenApiSpex.Schema{
           oneOf: [Schemas.IngestionBacklogError, Schemas.RateLimitError]
         }}
    }
  )

  @doc "POST /api/v1/knowledge/ingest"
  def create(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # Gate the SINGLE-item path on the same backlog valve as the batch path (US-36.3):
    # otherwise a tenant that 429s on /ingest/batch could keep piling :ingestion jobs
    # one-at-a-time by looping this endpoint, defeating the backpressure valve. Both
    # routes now consult the same threshold, so accumulation is bounded regardless of
    # which endpoint the flood comes through. Checked AFTER require_llm_key so a keyless
    # tenant still gets the clearer 422 first.
    with :ok <- require_llm_key(tenant_id),
         :ok <- check_ingestion_backlog(tenant_id) do
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
                 "metadata (optional). Per-item `content` obeys the same " <>
                 "#{@max_inline_content_bytes}-byte cap and is encrypted at rest; " <>
                 "`metadata` is not encrypted.",
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

  # US-36.3 admission gate: reject with 429 when the calling tenant's in-flight
  # :ingestion backlog is at/over the env-driven threshold, BEFORE enqueuing anything.
  # Consults the WORKER-scoped, index-backed count (`in_flight_ingestion_backlog/1` —
  # tenant-scoped by args->>'tenant_id', backed by the partial index
  # oban_jobs_ingestion_tenant_idx, bounded by a per-query statement_timeout via
  # AdminRepo) — cheap and scoped to the CALLER's own backlog ONLY, so one tenant's
  # backlog never affects another's admission NOR the query cost. Used by BOTH the batch
  # (create_batch/2) and single-item (create/2) ingest paths. The error tuple is rendered
  # by LoopctlWeb.FallbackController (structured 429 + Retry-After, code
  # "ingestion_backlog_exceeded" — distinct from the Hammer request-rate 429).
  #
  # SOFT ADMISSION HINT, not a hard cap. This is a plain read-then-enqueue with no lock
  # or atomic reservation, so it bounds ACCUMULATION probabilistically, not exactly: N
  # concurrent same-tenant requests can each observe count < max and each pass (a benign
  # TOCTOU), overshooting the threshold by up to the in-flight request concurrency. That
  # is by design — this is a backpressure VALVE to stop runaway monopolization, not a
  # guaranteed ceiling. Operators tuning OBAN_INGEST_BACKLOG_MAX should read it as a
  # "start shedding around here" floor, not an enforced maximum.
  defp check_ingestion_backlog(tenant_id) do
    max = ObanConfig.ingest_backlog_max()

    if in_flight_ingestion_backlog(tenant_id) >= max do
      {:error, :ingestion_backlog_exceeded, backlog_retry_after_seconds()}
    else
      :ok
    end
  end

  # FAIL OPEN on an UNMEASURABLE count only: an unreachable/timed-out backlog count must
  # never block work (an innocent, under-threshold tenant must never eat a generic 500
  # because the count path is momentarily degraded). The count runs under a 2s
  # `SET LOCAL statement_timeout`; a raised statement_timeout surfaces as `Postgrex.Error`
  # (57014 query_canceled) and a pool-checkout timeout as `DBConnection.ConnectionError`,
  # so we rescue ONLY those two classes — NOT a bare `rescue e ->`. A programming error
  # in the count path (e.g. a bad query change) must therefore propagate and 500, LOUD,
  # rather than be silently swallowed into a fleet-wide disabling of backpressure that
  # looks healthy. On the fail-open path we ALSO emit a telemetry counter
  # (`[:loopctl, :ingestion, :backlog_gate, :failed_open]`) so "the backpressure valve is
  # currently admitting because it can't measure" is an alertable signal, not just a
  # warning-log line, and a sustained per-request timeout under a real flood is visible on
  # a dashboard instead of only as log spam. The count is resolved through a
  # config-swappable DI seam (`Loopctl.Oban.FairShare` in prod, a Mox mock in test) so
  # this fail-open path is deterministically covered.
  defp in_flight_ingestion_backlog(tenant_id) do
    backlog_counter().in_flight_ingestion_backlog(tenant_id)
  rescue
    # `LocalGuc`'s capture ABORT shares `DBConnection.ConnectionError` with the transient
    # pool faults this clause is for. It is raised DELIBERATELY, so it gets its OWN
    # `error_class` (`fail_open_class/1`) rather than hiding inside "connection" — a refusal
    # whose purpose is to be noticed stays alertable. It still fails OPEN: an abort IS an
    # unmeasurable count, and this gate exists so an innocent, under-threshold tenant never
    # eats an error because the count path is momentarily degraded. See
    # `Loopctl.LocalGuc.capture_abort?/1`.
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      fail_open(tenant_id, e)
  end

  defp fail_open(tenant_id, e) do
    Logger.warning(
      "ingestion backlog gate failed open for tenant=#{tenant_id}: " <>
        Exception.message(e)
    )

    :telemetry.execute(
      TelemetryEvents.ingestion_backlog_gate_failed_open(),
      %{count: 1},
      %{tenant_id: tenant_id, error_class: fail_open_class(e)}
    )

    0
  end

  defp fail_open_class(%DBConnection.ConnectionError{} = e) do
    if LocalGuc.capture_abort?(e), do: "guc_capture_abort", else: "connection"
  end

  defp fail_open_class(%Postgrex.Error{}), do: "timeout"

  defp backlog_counter do
    Application.get_env(:loopctl, :ingestion_backlog_counter, FairShare)
  end

  # Retry-After hint (seconds) for a backlog-429. Tied to the :ingestion queue's DRAIN
  # cadence — NOT the sub-second fair-share snooze base. ContentIngestionWorker jobs are
  # ~6-min LLM calls on a width-2 queue, so a backlog drains on the order of minutes-to-
  # hours; advising a compliant client to retry in ~5s would just hot-loop it into a
  # steady stream of 429s (each re-running the admission count). A drain-cadence-scaled
  # value (env OBAN_INGEST_BACKLOG_RETRY_AFTER, default 60s, boot-validated) is an honest
  # "back off for a while" hint that keeps a Retry-After-honoring client off the endpoint
  # between real drains. Deploy-free-tunable like the threshold itself.
  defp backlog_retry_after_seconds do
    ObanConfig.ingest_backlog_retry_after_seconds()
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
    # #493 fail-loud: ContentEnvelope's contract states a vault misconfiguration
    # (missing CLOAK_KEY) is a boot-level fault the caller must never mask. Per-item
    # encryption below runs inside async_stream_nolink, where a Vault.encrypt! raise
    # is caught as {:exit, reason} and flattened into an opaque per-item
    # "validation_failed" — hiding a real key-provisioning failure. The fault is
    # global and deterministic, so probe the vault ONCE here (request process, before
    # the async boundary) when any item carries inline content; a misconfig then
    # propagates as a 500 exactly as it does on the single-item path.
    if Enum.any?(items, &inline_content_item?/1), do: ContentEnvelope.ensure_ready!()

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
         :ok <- validate_content_length(content),
         :ok <- validate_source_type(source_type),
         :ok <- validate_url_egress(url) do
      content_hash = compute_content_hash(tenant_id, url || content)

      # #493: inline document content is encrypted at rest (Cloak AES-256-GCM) BEFORE it
      # is written to `oban_jobs.args` — never plaintext in the jobs table. The URL path
      # carries no inline content (nil), so `maybe_put` drops the key exactly as before;
      # `content_hash` (a per-tenant HMAC blind index over url||content) still keys
      # uniqueness. `content_chunk_count` is the CLEARTEXT chunk count computed here from
      # the plaintext (a coarse size hint that leaks no content) so the worker's
      # `timeout/1` can size its budget WITHOUT decrypting+chunking the envelope on every
      # attempt (#493 review, finding 6).
      job_args =
        %{
          "tenant_id" => tenant_id,
          "content_hash" => content_hash,
          "source_type" => source_type
        }
        |> maybe_put("url", url)
        |> maybe_put("content_encrypted", encrypt_inline_content(content))
        |> maybe_put("content_chunk_count", inline_chunk_count(content))
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

  defp validate_content_source(url, nil) when is_binary(url), do: :ok
  defp validate_content_source(nil, content) when is_binary(content), do: :ok

  # A non-string `url`/`content` (e.g. a JSON object/array/number in the body) would
  # slip past the nil-checks above but then raise FunctionClauseError in
  # compute_content_hash/2 or encrypt_inline_content/1 (both is_binary-guarded),
  # turning adversarial/malformed input into a 500. Reject it as a clean 422 at the
  # write-path boundary instead (#493 review, finding 4).
  defp validate_content_source(_url, _content) do
    {:error, :unprocessable_entity, "'url' and 'content' must be strings"}
  end

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

  # #493 review: `content_hash` is a KEYED BLIND INDEX (HMAC-SHA256 under the app
  # secret, per tenant), NOT a bare SHA256 of the plaintext. A bare digest of the
  # document sitting in cleartext next to the ciphertext is an offline confirmation
  # oracle: a DB-read attacker could compute sha256(known_document) and match-to-
  # confirm whether that exact content was ingested — partially defeating #493's
  # "encrypted at rest" guarantee. Keying it under a server secret keeps the value
  # DETERMINISTIC (so Oban's [content_hash, tenant_id] dedup and the worker's derived
  # source_id still work) while making it uncomputable without the secret, and the
  # per-tenant key also stops correlation of identical documents across tenants.
  # Mirrors the `Loopctl.KeysetCursor` per-tenant HMAC-from-secret_key_base pattern.
  defp compute_content_hash(tenant_id, input) when is_binary(input) do
    :hmac
    |> :crypto.mac(:sha256, content_hash_secret(tenant_id), input)
    |> Base.encode16(case: :lower)
  end

  # Per-tenant HMAC key for the content_hash blind index: app secret_key_base +
  # a namespace infix + tenant_id. Stable across nodes without storing a per-tenant
  # secret. FAIL CLOSED: secret_key_base is fetched (not defaulted) — signing with a
  # guessable constant would defeat the blind index; runtime.exs requires
  # SECRET_KEY_BASE in prod and the test/dev configs set it, so this raise is a guard,
  # not a path.
  defp content_hash_secret(tenant_id) do
    base =
      :loopctl
      |> Application.fetch_env!(LoopctlWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    base <> ":knowledge_ingest_content_hash:" <> to_string(tenant_id)
  end

  # #493: nil (URL path) stays nil so `maybe_put` omits the key; inline content is
  # encrypted at rest before it ever reaches `oban_jobs.args`.
  defp encrypt_inline_content(nil), do: nil
  defp encrypt_inline_content(content) when is_binary(content), do: ContentEnvelope.wrap(content)

  # Cap inline `content` at the controller boundary (#493 review, findings 5/7).
  # Inline content is otherwise bounded only by the HTTP body limit; #493 now ENCRYPTS
  # + Base64-wraps it (~+33%) into oban_jobs.args JSONB, and the worker decrypts +
  # chunks the full body on EVERY attempt — so an oversized body amplifies both storage
  # and per-attempt CPU/memory. Reject an over-cap body as a clean 422 here (before any
  # crypto or enqueue) rather than after. Sized well above a large document (an ~87KB
  # newsletter) but bounded. URL-only ingests (content nil) skip this.
  # (@max_inline_content_bytes is declared at the top of the module so the OpenAPI
  # `maxLength` and this guard share one source of truth.)
  defp validate_content_length(content) when is_binary(content) do
    if byte_size(content) > @max_inline_content_bytes do
      {:error, :unprocessable_entity,
       "'content' exceeds the #{@max_inline_content_bytes}-byte inline limit; " <>
         "fetch larger documents via 'url' instead"}
    else
      :ok
    end
  end

  defp validate_content_length(_), do: :ok

  # #493 review (finding 6): compute the chunk count from the PLAINTEXT once, here at
  # enqueue, and persist it as a cleartext job arg so `ContentIngestionWorker.timeout/1`
  # can scale its wall-clock budget WITHOUT decrypting + chunking the envelope on every
  # attempt. The count is a coarse size hint that leaks no content. nil (URL path) omits
  # the arg via `maybe_put`.
  defp inline_chunk_count(nil), do: nil

  defp inline_chunk_count(content) when is_binary(content),
    do: content |> ContentChunker.chunk() |> length()

  # Does this batch item carry inline document content (vs a URL-only item)?
  # Used to gate the pre-async vault readiness probe so a URL-only batch does no
  # needless crypto work.
  defp inline_content_item?(%{"content" => content}) when is_binary(content) and content != "",
    do: true

  defp inline_content_item?(_), do: false

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
