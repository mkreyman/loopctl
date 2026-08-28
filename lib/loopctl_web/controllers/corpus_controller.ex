defmodule LoopctlWeb.CorpusController do
  @moduledoc """
  The CORPUS TIER surface (Epic 43) — the index loopctl hosts for reference documents
  whose physical files stay in the client's own repo.

  Retrieval returns a POINTER plus a snippet, never a body: the agent is told page 47
  of a named file and opens the file itself. That is what keeps the file the source of
  truth and lets the tier be pointed at a repo loopctl does not own.

  | route | role | why |
  |---|---|---|
  | `POST /api/v1/corpora` | `:agent` | non-destructive and audited — the criteria that earn the KB content surface its agent role |
  | `GET /api/v1/corpora` | `:agent` | a read |
  | `GET /api/v1/corpora/:id` | `:agent` | a read |
  | `GET /api/v1/corpora/:id/status` | `:agent` | a read |
  | `POST /api/v1/corpora/:id/index` | `:agent` | it DOES delete, but neither set-based nor a one-way door: the prune reaches only `source_ref`s the SAME request carries chunks for and names complete, and re-indexing the file restores them |
  | `POST /api/v1/corpora/:id/search` | `:agent` | a POST-shaped read (the query body is richer than a query string) |
  | `DELETE /api/v1/corpora/:id` | `:user` | set-based blast radius AND irreversible: one call destroys every chunk and vector in the corpus and nothing restores them |

  Every MUTATING verb — create, index and delete — writes its audit entry inside the
  mutation's own transaction (AC-43.2.7), so a corpus that could not be recorded is
  neither created nor destroyed: the audit step failing rolls the write back and answers
  `500 audit_write_failed`.

  `DELETE` is the one verb that is both set-based and irrecoverable, which is exactly
  the CLAUDE.md test for the `:user` line. `index`'s delete is bounded by AC-43.2.3's
  reconciliation rule, so it stays below it.

  ## `corpus_search` is NOT a recall surface

  It must NEVER be wired into `/api/v1/recall`. That hook injects into every repo's
  session, and verbatim spec chunks there are precisely the pollution the corpus tier's
  separate tables exist to prevent BY CONSTRUCTION.

  ## Mode A is mandatory-BYO, and the failure is moved forward

  A `server_embedded` corpus embeds SERVER-SIDE on the TENANT's own embedding key, so a
  keyless tenant is refused at `create` with a coded 422 and the embedding remediation —
  not at first index, long after the call that could have said so.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Corpus
  alias Loopctl.Corpus.Indexer
  alias Loopctl.Corpus.Search
  alias Loopctl.Llm
  alias Loopctl.RateLimiter
  alias Loopctl.RateLimiter.FailOpenLog
  alias Loopctl.Tenants
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  # Mandatory BYO: mode A embeds on the tenant's OWN key. Refuse up front so no corpus
  # is created that can only fail at its first index (AC-43.2.9).
  @no_embedding_key_message "Configure your embedding API key before creating a " <>
                              "server_embedded corpus. Mode A embeds SERVER-SIDE on your own " <>
                              "key — loopctl is BYO — so provision it ONCE via the " <>
                              "set_llm_config MCP tool (user role), or PATCH " <>
                              "/api/v1/tenants/me/llm-config. See the response `remediation` " <>
                              "for the exact call."

  # Declared HERE, above the `operation/2` specs, and sourced from the ONE function that
  # also enforces them, so the published OpenAPI bounds and the runtime guards read the
  # same numbers and cannot drift (the `@max_inline_content_bytes` precedent).
  @max_batch_size Indexer.max_batch_size()
  @max_snippet_chars Search.max_snippet_chars()
  @max_search_limit Search.max_limit()
  @max_query_chars Search.max_query_chars()

  @rate_limit_window_ms 60_000

  # A generic 2xx envelope for the responses whose payload is documented in prose
  # rather than as a named schema (there is no shared success schema in `Schemas`).
  @ok_object %OpenApiSpex.Schema{type: :object}

  # Per-minute caps. `search` is charged once per REQUEST and is clamped below the
  # pipeline per-key default, so the specific 429 stays the binding, observable
  # constraint instead of being shadowed by an anonymous pipeline 429. `index` is charged
  # per ITEM (one request may carry @max_batch_size chunks), which is why its cap is the
  # larger number — and why it is NOT clamped against a per-request setting.
  @default_index_limit 240
  @default_search_limit 120
  @pipeline_per_key_limit_default 300

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:create, :index, :show, :status, :ingest, :search]

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:delete]

  plug :rate_limit_ingest when action in [:ingest]
  plug :rate_limit_search when action in [:search]

  tags(["Corpus"])

  operation(:create,
    summary: "Create a document corpus",
    description:
      "Creates a corpus that pins its own embedding model and dimension. Role: agent+. " <>
        "In mode server_embedded loopctl embeds the chunk text you send, on YOUR embedding " <>
        "key — a tenant with no embedding credential is refused here (422 no_embedding_key) " <>
        "rather than at first index. A declared dim that disagrees with the model's native " <>
        "dimension is refused too; an UNKNOWN model is accepted (the server cannot check it).",
    request_body:
      {"Corpus attributes", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:slug, :name, :mode, :embedding_model, :dim],
         properties: %{
           slug: %OpenApiSpex.Schema{type: :string, maxLength: 100},
           name: %OpenApiSpex.Schema{type: :string},
           description: %OpenApiSpex.Schema{type: :string},
           mode: %OpenApiSpex.Schema{type: :string, enum: ["server_embedded", "client_embedded"]},
           embedding_model: %OpenApiSpex.Schema{type: :string},
           dim: %OpenApiSpex.Schema{type: :integer},
           allow_snippets: %OpenApiSpex.Schema{type: :boolean},
           project_id: %OpenApiSpex.Schema{type: :string, format: :uuid}
         }
       }},
    responses: %{
      201 => {"Created", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Insufficient role", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Validation failed, or no embedding key for mode A", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"Audit write failed — the corpus was NOT created", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/corpora"
  def create(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    attrs = Map.drop(params, ["_json"])

    with :ok <- require_embedding_key(tenant_id, Map.get(attrs, "mode")),
         {:ok, corpus} <- Corpus.create_corpus(tenant_id, attrs, AuditContext.from_conn(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: render_corpus(corpus)})
    end
  end

  operation(:index,
    summary: "List document corpora",
    description: "Lists this tenant's corpora, newest first. Role: agent+.",
    parameters: [
      project_id: [in: :query, type: :string, description: "Restrict to one project scope."],
      limit: [in: :query, type: :integer, description: "Page size (clamped)."],
      offset: [in: :query, type: :integer, description: "Rows to skip."]
    ],
    responses: %{
      200 => {"Corpora", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/corpora"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      [
        project_id: Map.get(params, "project_id"),
        limit: to_int(Map.get(params, "limit")),
        offset: to_int(Map.get(params, "offset"))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    json(conn, %{data: Enum.map(Corpus.list_corpora(tenant_id, opts), &render_corpus/1)})
  end

  operation(:show,
    summary: "Get one corpus with its status",
    description:
      "Returns the corpus and its aggregate index status (source and chunk counts). " <>
        "Accepts an id or a slug. Role: agent+.",
    parameters: [
      id: [in: :path, type: :string, description: "Corpus id or slug.", required: true]
    ],
    responses: %{
      200 => {"Corpus", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/corpora/:id"
  def show(conn, %{"id" => id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, corpus} <- Corpus.get_corpus(tenant_id, id),
         {:ok, counts} <- Corpus.source_status(tenant_id, corpus.id, limit: 1) do
      json(conn, %{
        data:
          Map.put(render_corpus(corpus), :status, %{
            has_sources: counts.sources != [] or counts.has_more
          })
      })
    end
  end

  operation(:status,
    summary: "Per-source index status",
    description:
      "One row per source_ref with its chunk count and a content hash over that source's " <>
        "chunks, so a client indexes only what moved instead of resubmitting the corpus. " <>
        "BOUNDED and paginated — a corpus with thousands of sources does not come back in " <>
        "one body. Role: agent+.",
    parameters: [
      id: [in: :path, type: :string, description: "Corpus id or slug.", required: true],
      limit: [in: :query, type: :integer, description: "Sources per page (clamped)."],
      offset: [in: :query, type: :integer, description: "Sources to skip."]
    ],
    responses: %{
      200 => {"Per-source status", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/corpora/:id/status"
  def status(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      [limit: to_int(Map.get(params, "limit")), offset: to_int(Map.get(params, "offset"))]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, result} <- Corpus.source_status(tenant_id, id, opts) do
      json(conn, %{
        data: result.sources,
        meta: %{
          corpus_id: result.corpus.id,
          limit: result.limit,
          offset: result.offset,
          has_more: result.has_more
        }
      })
    end
  end

  operation(:delete,
    summary: "Delete a corpus",
    description:
      "Destroys the corpus, every chunk in it and every vector, via the declared cascade. " <>
        "IRREVERSIBLE and set-based, which is why it is role: user while every other verb " <>
        "on this surface is agent+. The delete and its audit entry share one transaction: " <>
        "an audit write that fails rolls the delete back (500 audit_write_failed).",
    parameters: [
      id: [in: :path, type: :string, description: "Corpus id or slug.", required: true]
    ],
    responses: %{
      200 => {"Deleted", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Insufficient role", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      500 =>
        {"Audit write failed — the corpus was NOT deleted", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @doc "DELETE /api/v1/corpora/:id"
  def delete(conn, %{"id" => id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, corpus} <- Corpus.delete_corpus(tenant_id, id, AuditContext.from_conn(conn)) do
      json(conn, %{data: render_corpus(corpus)})
    end
  end

  operation(:ingest,
    summary: "Index a batch of chunks",
    description:
      "Accepts up to #{@max_batch_size} chunks, each {source_ref, locator, text, ordinal}. " <>
        "content_hash is computed SERVER-SIDE from the text and is not accepted from the " <>
        "client in mode A. Indexing is idempotent on (corpus_id, source_ref, locator): an " <>
        "unchanged batch writes nothing, spends no embedding tokens, and reports every item " <>
        "as unchanged; a chunk whose text is unchanged but whose snippet or ordinal moved is " <>
        "reported replaced — the row is rewritten and no embedding is spent. Name a source in " <>
        "source_complete ONLY when this request carries that source in FULL — a named source " <>
        "is reconciled against THIS request alone, so every stored chunk of it the request " <>
        "does not carry is deleted, and meta.pruned_by_source reports what each name cost. A " <>
        "source larger than the batch ceiling therefore cannot be reconciled in one request: " <>
        "index it across batches without naming it. Naming a source the batch does not carry " <>
        "is refused. Rate limited per ITEM. Role: agent+.",
    parameters: [
      id: [in: :path, type: :string, description: "Corpus id or slug.", required: true]
    ],
    request_body:
      {"Chunk batch", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:chunks],
         properties: %{
           chunks: %OpenApiSpex.Schema{
             type: :array,
             maxItems: @max_batch_size,
             items: %OpenApiSpex.Schema{
               type: :object,
               required: [:source_ref, :text],
               properties: %{
                 source_ref: %OpenApiSpex.Schema{type: :string},
                 locator: %OpenApiSpex.Schema{
                   description:
                     "Opaque client-owned pointer (object, array or scalar), stored verbatim."
                 },
                 text: %OpenApiSpex.Schema{type: :string},
                 ordinal: %OpenApiSpex.Schema{type: :integer},
                 snippet: %OpenApiSpex.Schema{type: :string, maxLength: @max_snippet_chars}
               }
             }
           },
           source_complete: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string},
             description: "The source_refs this request carries in FULL."
           }
         }
       }},
    responses: %{
      200 => {"Per-item index report", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Insufficient role", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Invalid batch", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"Audit write failed — nothing was written", "application/json", Schemas.ErrorResponse},
      502 => {"Embedding failed — nothing was written", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/corpora/:id/index"
  def ingest(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts = [
      source_complete: Map.get(params, "source_complete"),
      audit: AuditContext.from_conn(conn)
    ]

    case Indexer.index_chunks(tenant_id, id, chunk_params(params), opts) do
      {:ok, result} ->
        json(conn, %{
          data: result.items,
          meta: %{
            corpus_id: result.corpus.id,
            pruned: result.pruned,
            pruned_by_source: result.pruned_by_source,
            counts: Enum.frequencies_by(result.items, & &1.status)
          }
        })

      {:error, reason} ->
        handle_index_error(conn, reason)
    end
  end

  operation(:search,
    summary: "Search a corpus for pointers",
    description:
      "Embeds the query with the CORPUS's pinned model and runs both lanes — semantic over " <>
        "the per-dimension HNSW index and keyword over the chunk text — fused by the same " <>
        "Reciprocal Rank Fusion the article path uses. Returns {source_ref, locator, snippet, " <>
        "score, corpus_id, chunk_id} by descending score and NEVER the full chunk text. " <>
        "meta.lanes names the lanes that actually ran. Scores are RANK-derived and comparable " <>
        "only WITHIN one result set — there is no absolute floor. Role: agent+. This endpoint " <>
        "is deliberately NOT part of /api/v1/recall.",
    parameters: [
      id: [in: :path, type: :string, description: "Corpus id or slug.", required: true]
    ],
    request_body:
      {"Search request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:query],
         properties: %{
           query: %OpenApiSpex.Schema{type: :string, maxLength: @max_query_chars},
           limit: %OpenApiSpex.Schema{type: :integer, maximum: @max_search_limit}
         }
       }},
    responses: %{
      200 =>
        {"Ranked pointers", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: %OpenApiSpex.Schema{
                 type: :object,
                 properties: %{
                   chunk_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
                   corpus_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
                   source_ref: %OpenApiSpex.Schema{type: :string},
                   locator: %OpenApiSpex.Schema{
                     description: "The client's own pointer, verbatim."
                   },
                   snippet: %OpenApiSpex.Schema{
                     type: :string,
                     maxLength: @max_snippet_chars,
                     description:
                       "A bounded excerpt — NEVER the full chunk text. Open the file at " <>
                         "source_ref/locator for the rest."
                   },
                   score: %OpenApiSpex.Schema{type: :number}
                 }
               }
             },
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Empty or over-long query, or a client_embedded corpus", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 => {"Both lanes shed under load", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/corpora/:id/search"
  def search(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    opts = [limit: to_int(Map.get(params, "limit"))] |> Enum.reject(&is_nil(elem(&1, 1)))

    case Search.search(tenant_id, id, Map.get(params, "query"), opts) do
      {:ok, result} ->
        json(conn, %{data: result.results, meta: result.meta})

      {:error, :empty_query} ->
        error(conn, 422, "empty_query", "A query string is required.")

      {:error, :query_too_long} ->
        error(conn, 422, "query_too_long", query_too_long_message())

      {:error, :mode_mismatch} ->
        error(conn, 422, "mode_mismatch", search_mode_mismatch_message())

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- error rendering ---

  defp handle_index_error(conn, :mode_mismatch) do
    error(
      conn,
      422,
      "mode_mismatch",
      "This corpus is client_embedded: it stores vectors the server cannot read, so it " <>
        "does not accept chunk text on this endpoint."
    )
  end

  defp handle_index_error(conn, {:batch_too_large, max}) do
    error(conn, 422, "batch_too_large", batch_too_large_message(max))
  end

  defp handle_index_error(conn, {:invalid_chunk, index, %Ecto.Changeset{} = changeset}) do
    error(conn, 422, "invalid_chunk", "chunks[#{index}] is invalid.", %{
      index: index,
      errors: changeset_errors(changeset)
    })
  end

  defp handle_index_error(conn, {:invalid_chunk, index, message}) do
    error(conn, 422, "invalid_chunk", "chunks[#{index}]: #{message}", %{index: index})
  end

  defp handle_index_error(conn, {:duplicate_chunk_key, {source_ref, locator}}) do
    error(
      conn,
      422,
      "duplicate_chunk_key",
      "Two chunks in this batch share one (source_ref, locator). Postgres cannot affect " <>
        "the same row twice in one upsert, and keeping the last one would hide a chunking bug.",
      %{source_ref: source_ref, locator: locator}
    )
  end

  defp handle_index_error(conn, {:source_complete_not_carried, missing}) do
    error(
      conn,
      422,
      "source_complete_not_carried",
      "source_complete may name only sources this request carries chunks for — otherwise a " <>
        "request could prune content it never resent.",
      %{missing: missing}
    )
  end

  defp handle_index_error(conn, {:embedding_failed, reason, failed}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        status: 502,
        code: "embedding_failed",
        message:
          "The batch could not be embedded, so NOTHING was written — chunk and vector alike. " <>
            "Correct the named items and resubmit the whole batch; re-indexing is idempotent, " <>
            "so the unchanged members cost nothing.",
        reason: inspect(reason),
        failed_items: failed
      }
    })
  end

  # A step OTHER than `:audit` failed and rolled the whole request back — a changeset
  # the per-chunk validation could not have caught (a vector at the wrong dimension for
  # this corpus, a constraint violation). Rendered as an explicit 500 rather than left
  # to the FallbackController, which has no clause for this term and would answer with
  # an unhandled-error page instead of a code the caller can branch on.
  defp handle_index_error(conn, {:write_failed, step, reason}) do
    Logger.error(
      "corpus index write failed at step #{inspect(step)}: #{inspect(reason)} " <>
        "(the whole batch rolled back)"
    )

    error(
      conn,
      500,
      "corpus_write_failed",
      "The batch could not be written and was rolled back in full; nothing was persisted."
    )
  end

  # `:not_found` and `:audit_write_failed` are the FallbackController's to render — the
  # latter as the 500 that tells the caller the write did NOT happen so it retries.
  defp handle_index_error(_conn, reason), do: {:error, reason}

  defp error(conn, status, code, message, details \\ nil) do
    body = %{status: status, code: code, message: message}

    conn
    |> put_status(status)
    |> json(%{error: if(details, do: Map.put(body, :details, details), else: body)})
  end

  # The mode refusal the INGEST verb already gives, in the read verb's own words: both
  # halves of the surface refuse a client_embedded corpus identically, rather than one
  # answering a coded 422 and the other spending a provider embedding call to return an
  # empty set with a 200.
  defp search_mode_mismatch_message,
    do:
      "This corpus is client_embedded: it stores vectors loopctl did not make and cannot " <>
        "read, so the server cannot embed a query against it."

  defp query_too_long_message,
    do: "The query is longer than #{@max_query_chars} characters."

  # States the rule the code ENFORCES, which is not the one this message used to give.
  # `source_complete` is reconciled against THIS request alone: every stored chunk of a
  # named source that the request does not carry is deleted. Naming a source on the LAST
  # batch of a split document therefore deletes the earlier batches. So a source is named
  # only by a request that carries it in FULL, which bounds a reconcilable source at the
  # batch ceiling; a larger source is indexed across batches and simply not reconciled.
  defp batch_too_large_message(max) do
    "A batch carries at most #{max} chunks. Split the document across several requests, " <>
      "and name a source in source_complete ONLY on a request that carries that source in " <>
      "FULL — a named source is reconciled against that one request, so every stored chunk " <>
      "of it the request does not carry is deleted. A source larger than #{max} chunks " <>
      "cannot be reconciled in one request: index it across batches without naming it."
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(inspect(value)))
      end)
    end)
  end

  # --- BYO gate (AC-43.2.9) ---

  defp require_embedding_key(tenant_id, "server_embedded") do
    if Llm.has_embedding_key?(tenant_id) do
      :ok
    else
      Llm.record_blocked(tenant_id, :embedding)
      {:error, :no_embedding_key_configured, @no_embedding_key_message}
    end
  end

  defp require_embedding_key(_tenant_id, _mode), do: :ok

  # --- rate limiting (function plugs) ---

  # AC-43.2.7: charged per ITEM, not per request. `check_rate/3` increments by ONE per
  # call, so the charge is explicit: one call per chunk, short-circuiting on the first
  # denial. Without it a client could submit @max_batch_size chunks per request and pay
  # the same as a client submitting one.
  #
  # The batch ceiling is applied HERE, before the charge, and not only inside the action:
  # a controller plug runs first, so an over-size batch would otherwise spend the
  # tenant's whole per-minute index budget one item at a time and come back as an opaque
  # 429 — for a request that is invalid on its face, wrote nothing, and reproduces the
  # same 429 on every retry while refusing a well-formed batch in the same window. The
  # 422 that NAMES the ceiling is the one the caller can act on, so it wins the race, and
  # both refusals read the same `@max_batch_size` and the same message.
  defp rate_limit_ingest(conn, _opts) do
    items = conn.body_params |> chunk_params() |> length()

    if items > @max_batch_size do
      conn
      |> error(422, "batch_too_large", batch_too_large_message(@max_batch_size))
      |> halt()
    else
      gate(conn, "corpus_index:tenant:#{tenant_id(conn)}", ingest_limit(conn), max(items, 1))
    end
  end

  defp rate_limit_search(conn, _opts) do
    gate(conn, "corpus_search:tenant:#{tenant_id(conn)}", search_limit(conn), 1)
  end

  # Bucketed per TENANT, not per key: indexing and searching a corpus are TENANT
  # resources (one provider bill, one HeavyRead budget), and a per-key bucket would let
  # a tenant multiply its own ceiling by minting keys — which, under the v2 dispatch
  # pattern, it does routinely (one ephemeral key per dispatch).
  defp tenant_id(conn), do: conn.assigns.current_api_key.tenant_id

  defp gate(conn, bucket, limit, charges) do
    if charge(bucket, limit, charges) do
      conn
    else
      retry_after = max(1, window_reset_at() - System.system_time(:second))

      conn
      |> put_resp_header("retry-after", to_string(retry_after))
      |> put_status(:too_many_requests)
      |> json(%{error: %{status: 429, code: "rate_limited", message: "Rate limit exceeded"}})
      |> halt()
    end
  end

  # `within_limit?/3` normalises the `{:error, term()}` the behaviour also permits and
  # fails OPEN through the shared throttled `FailOpenLog`, so a limiter outage degrades
  # to "no gate" rather than a CaseClauseError 500.
  defp charge(bucket, limit, charges) do
    Enum.reduce_while(1..charges, true, fn _charge, _acc ->
      if RateLimiter.within_limit?(bucket, @rate_limit_window_ms, limit) do
        {:cont, true}
      else
        {:halt, false}
      end
    end)
  rescue
    error ->
      FailOpenLog.warn(:corpus, bucket, Exception.message(error))
      true
  end

  # NOT clamped against the pipeline cap, unlike `search_limit/1`. This bucket is charged
  # per ITEM while `rate_limit_requests_per_minute` is charged once per REQUEST, so a
  # `min/2` of the two puts a request count into an item ceiling: a tenant that lowered
  # the pipeline setting to 60 — an ordinary conservative throttle — would have every
  # batch above 60 chunks refused in every window, permanently, while the OpenAPI
  # `maxItems` kept advertising #{@max_batch_size} and nothing in the 429 named the
  # cause. The ChannelPostController clamp this idiom comes from is unit-consistent
  # because its buckets are charged per request; this one is not.
  defp ingest_limit(conn),
    do: configured_limit(conn, "corpus_index_limit_per_minute", @default_index_limit)

  defp search_limit(conn),
    do: clamped_limit(conn, "corpus_search_limit_per_minute", @default_search_limit)

  defp configured_limit(conn, setting, default) do
    conn.assigns[:current_tenant]
    |> setting_value(setting, default)
    |> coerce_positive_int(default)
  end

  # Clamped BELOW the generic per-key pipeline limiter, which runs FIRST and emits no
  # corpus-specific signal: a tenant that raised this setting above the pipeline cap
  # would see every corpus trip shadowed by an anonymous pipeline 429. Sound HERE and
  # only here — search is charged one token per request, the same unit the pipeline cap
  # counts in.
  defp clamped_limit(conn, setting, default) do
    pipeline =
      conn.assigns[:current_tenant]
      |> setting_value("rate_limit_requests_per_minute", @pipeline_per_key_limit_default)
      |> coerce_positive_int(@pipeline_per_key_limit_default)

    min(configured_limit(conn, setting, default), pipeline)
  end

  defp setting_value(nil, _setting, default), do: default

  defp setting_value(tenant, setting, default),
    do: Tenants.get_tenant_settings(tenant, setting, default)

  defp coerce_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp coerce_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp coerce_positive_int(_value, default), do: default

  defp window_reset_at do
    now = System.system_time(:second)
    (div(now, 60) + 1) * 60
  end

  # --- shaping ---

  defp chunk_params(%{"chunks" => chunks}) when is_list(chunks), do: chunks
  defp chunk_params(_params), do: []

  defp render_corpus(corpus) do
    %{
      id: corpus.id,
      slug: corpus.slug,
      name: corpus.name,
      description: corpus.description,
      mode: corpus.mode,
      embedding_model: corpus.embedding_model,
      dim: corpus.dim,
      allow_snippets: corpus.allow_snippets,
      project_id: corpus.project_id,
      inserted_at: corpus.inserted_at,
      updated_at: corpus.updated_at
    }
  end

  defp to_int(nil), do: nil
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_value), do: nil
end
