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
  | `POST /api/v1/corpora/:id/index` | `:agent` | it DOES delete, but the delete set is the exact complement of a set the caller wrote down: the prune reaches only `source_ref`s the request both carries chunks for AND names complete, keeps every chunk the name's manifest declares, and re-indexing the file restores what it took |
  | `POST /api/v1/corpora/:id/search` | `:agent` | a POST-shaped read (the query body is richer than a query string) |
  | `DELETE /api/v1/corpora/:id` | `:user` | set-based blast radius AND irreversible: one call destroys every chunk and vector in the corpus and nothing restores them |

  Every MUTATING verb — create, index and delete — writes its audit entry inside the
  mutation's own transaction (AC-43.2.7), so a corpus that could not be recorded is
  neither created nor destroyed: the audit step failing rolls the write back and answers
  `500 audit_write_failed`.

  `DELETE` is the one verb that is both set-based and irrecoverable, which is exactly
  the CLAUDE.md test for the `:user` line — an AND, and `index`'s delete fails BOTH
  halves of it. It is scoped to one explicitly named `source_ref` at a time, keeps
  everything the caller either resent or listed in that source's manifest, refuses a bare
  name whose prune would exceed what the request carried, reports what each name cost in
  `meta.pruned_by_source` AND in the audit entry — and it is RECOVERABLE, because the
  file it indexes is the client's and re-indexing restores what a prune took. That last
  property is the one this tier is built on: the pointer keeps the file the source of
  truth, so nothing here is a one-way door.

  ## `corpus_search` is NOT a recall surface

  It must NEVER be wired into `/api/v1/recall`. That hook injects into every repo's
  session, and verbatim spec chunks there are precisely the pollution the corpus tier's
  separate tables exist to prevent BY CONSTRUCTION.

  ## Mode B: loopctl stores and ranks vectors it cannot read (US-43.3)

  A `client_embedded` corpus is indexed with `{source_ref, locator, vector,
  content_hash, ordinal, snippet?}`. There is NO parameter on this surface that accepts
  chunk text for such a corpus, and a chunk carrying `text` is refused
  (`422 text_not_accepted`) rather than silently ignored. `content_hash` is
  CLIENT-SUPPLIED and opaque — loopctl holds no text to hash and cannot verify the hash
  corresponds to the vector or to the file; the client owns that correspondence.
  Retrieval is semantic-only (there is no text to index) and takes a client-supplied
  `query_vector`. Every mode mismatch on this surface is a coded 422 with a remedy,
  never an empty 200 — an agent reads an empty result set as an empty corpus.

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
  alias Loopctl.Corpus.DocumentChunkEmbedding
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
  @max_source_manifest Indexer.max_source_manifest()
  @max_snippet_chars Search.max_snippet_chars()
  @max_search_limit Search.max_limit()
  @max_query_chars Search.max_query_chars()
  @search_lanes Search.lanes()
  @float32_max DocumentChunkEmbedding.float32_max()

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
        "dimension is refused too; an UNKNOWN model is accepted (the server cannot check it). " <>
        "In mode client_embedded loopctl never embeds anything: you send vectors and it " <>
        "stores content it cannot read, so no embedding key is required and " <>
        "allow_snippets defaults to FALSE — the privacy-preserving default, since a " <>
        "snippet IS text the server would then hold. Ask for it explicitly if you want it.",
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
      "Returns the corpus and ONE aggregate: status.has_sources, a boolean saying " <>
        "whether anything is indexed in it yet. Per-source chunk counts and content " <>
        "hashes are NOT here — they are GET /api/v1/corpora/:id/status, which is " <>
        "bounded and paginated. Accepts an id or a slug. Role: agent+.",
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

    with {:ok, corpus} <- Corpus.get_corpus(tenant_id, id) do
      json(conn, %{
        data:
          Map.put(render_corpus(corpus), :status, %{
            has_sources: Corpus.any_chunks?(tenant_id, corpus.id)
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
      "Accepts up to #{@max_batch_size} chunks. In a server_embedded corpus each chunk is " <>
        "{source_ref, locator, text, ordinal} and content_hash is computed SERVER-SIDE from " <>
        "the text, not accepted from the client. In a client_embedded corpus each chunk is " <>
        "{source_ref, locator, vector, content_hash, ordinal, snippet?}: there is NO text " <>
        "parameter, and a chunk carrying text is refused (422 text_not_accepted) rather " <>
        "than silently ignored, because dropping it would let you believe the keyword lane " <>
        "works on a corpus with no text to index. In that mode content_hash is yours and is " <>
        "treated as an OPAQUE IDEMPOTENCY TOKEN, never as an integrity proof — loopctl " <>
        "cannot verify that it corresponds to the vector or to the file, and you own that " <>
        "correspondence. The vector's length must equal the corpus dim (422 " <>
        "vector_dimension_mismatch, naming both numbers), and nothing verifies which model " <>
        "produced it: that is not computable from a vector. A snippet is refused (422 " <>
        "snippets_not_allowed) unless the corpus was created with allow_snippets true, " <>
        "which for a client_embedded corpus defaults to FALSE. Indexing is idempotent on (corpus_id, source_ref, locator): an " <>
        "unchanged batch writes nothing, spends no embedding tokens, and reports every item " <>
        "as unchanged; a chunk whose text is unchanged but whose snippet or ordinal moved is " <>
        "reported replaced — the row is rewritten and no embedding is spent. source_complete " <>
        "names the sources to RECONCILE, and each name declares that source's COMPLETE chunk " <>
        "set: a bare string means the set is what THIS request carries for it, while " <>
        "{source_ref, locators} declares the set explicitly so a document spanning several " <>
        "batches can be reconciled on the batch that completes it without deleting what the " <>
        "earlier batches wrote. Every stored chunk of a named source that is neither carried " <>
        "nor declared is deleted, and meta.pruned_by_source reports what each name cost. " <>
        "Naming a source the batch does not carry is refused, as is a manifest that omits a " <>
        "chunk the same request carries, as is a BARE name whose prune would exceed the " <>
        "number of chunks the request carries for that source (declare the locators " <>
        "instead). Rate limited per ITEM. Role: agent+.",
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
               oneOf: [
                 %OpenApiSpex.Schema{
                   type: :object,
                   title: "ServerEmbeddedChunk",
                   description:
                     "A chunk for a server_embedded corpus. content_hash is computed " <>
                       "server-side from the text and is not accepted here.",
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
                 },
                 %OpenApiSpex.Schema{
                   type: :object,
                   title: "ClientEmbeddedChunk",
                   description:
                     "A chunk for a client_embedded corpus. There is no text property: " <>
                       "sending one is refused, not ignored. content_hash is YOURS and is " <>
                       "an opaque idempotency token — loopctl cannot verify that it " <>
                       "corresponds to the vector or to the file, and you own that " <>
                       "correspondence. snippet is accepted only when the corpus allows " <>
                       "snippets, which defaults to false in this mode.",
                   required: [:source_ref, :vector, :content_hash],
                   properties: %{
                     source_ref: %OpenApiSpex.Schema{type: :string},
                     locator: %OpenApiSpex.Schema{
                       description:
                         "Opaque client-owned pointer (object, array or scalar), stored verbatim."
                     },
                     vector: %OpenApiSpex.Schema{
                       type: :array,
                       items: %OpenApiSpex.Schema{type: :number},
                       description:
                         "The locally-produced embedding. Its length must equal the " <>
                           "corpus dim, and every element must be float32-representable " <>
                           "(magnitude at most #{@float32_max}) — pgvector stores float32, " <>
                           "so a larger value is refused (422 vector_out_of_range) rather " <>
                           "than silently dropped."
                     },
                     content_hash: %OpenApiSpex.Schema{type: :string},
                     ordinal: %OpenApiSpex.Schema{type: :integer},
                     snippet: %OpenApiSpex.Schema{type: :string, maxLength: @max_snippet_chars}
                   }
                 }
               ]
             }
           },
           source_complete: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{
               oneOf: [
                 %OpenApiSpex.Schema{
                   type: :string,
                   description:
                     "A source_ref whose COMPLETE chunk set is what this request carries."
                 },
                 %OpenApiSpex.Schema{
                   type: :object,
                   required: [:source_ref, :locators],
                   properties: %{
                     source_ref: %OpenApiSpex.Schema{type: :string},
                     locators: %OpenApiSpex.Schema{
                       type: :array,
                       maxItems: @max_source_manifest,
                       description:
                         "The source's COMPLETE locator set. Chunks at these locators are " <>
                           "kept even when this request does not carry them, which is how a " <>
                           "document larger than the batch ceiling is reconciled. Must " <>
                           "include every locator this request carries for the source."
                     }
                   }
                 }
               ]
             },
             description: "The sources to reconcile, each declaring its complete chunk set."
           }
         }
       }},
    responses: %{
      200 => {"Per-item index report", "application/json", @ok_object},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Insufficient role", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Invalid batch — includes text_not_accepted, vector_dimension_mismatch, " <>
           "vector_out_of_range and snippets_not_allowed", "application/json",
         Schemas.ErrorResponse},
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
      "In a server_embedded corpus, embeds the query with the CORPUS's pinned model and " <>
        "runs both lanes — semantic over the per-dimension HNSW index and keyword over the " <>
        "chunk text — fused by the same " <>
        "Reciprocal Rank Fusion the article path uses. A client_embedded corpus is " <>
        "SEMANTIC-ONLY, because there is no text to index: send query_vector (validated " <>
        "against the corpus dim) instead of query, and meta.lanes is [semantic]. Sending a " <>
        "query STRING to a client_embedded corpus is refused (422 " <>
        "query_string_not_accepted) rather than answered with an empty set, as is sending " <>
        "a query_vector to a server_embedded one (422 query_vector_not_accepted) and asking " <>
        "for the keyword lane on a client_embedded one (422 keyword_lane_unavailable). The " <>
        "result and meta key sets are the same in both modes, so branch on meta rather than " <>
        "on the mode. Returns {source_ref, locator, snippet, " <>
        "score, corpus_id, chunk_id} by descending score and NEVER the full chunk text. " <>
        "meta.lanes names the lanes that actually ran, and meta.semantic_under_filled says " <>
        "when the semantic lane ran but could not reach the whole corpus. Scores are " <>
        "RANK-derived and comparable " <>
        "only WITHIN one result set — there is no absolute floor. Role: agent+. This endpoint " <>
        "is deliberately NOT part of /api/v1/recall.",
    parameters: [
      id: [in: :path, type: :string, description: "Corpus id or slug.", required: true]
    ],
    request_body:
      {"Search request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         description: "Exactly one of query (server_embedded) or query_vector (client_embedded).",
         properties: %{
           query: %OpenApiSpex.Schema{
             type: :string,
             maxLength: @max_query_chars,
             description:
               "A query string. server_embedded corpora only. Send this OR query_vector, " <>
                 "never both."
           },
           query_vector: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :number},
             description:
               "A locally-produced query vector whose length equals the corpus dim and " <>
                 "whose elements are float32-representable (magnitude at most " <>
                 "#{@float32_max}). client_embedded corpora only — the server cannot " <>
                 "embed for them. Send this OR query, never both."
           },
           lanes: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string, enum: @search_lanes},
             description:
               "The lanes to run (default: all available). A client_embedded corpus " <>
                 "offers only the semantic lane; asking for keyword there is refused."
           },
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
        {"Empty or over-long query (empty_query, query_too_long), both query and " <>
           "query_vector given (ambiguous_query), a query/corpus mode " <>
           "mismatch (query_string_not_accepted, query_vector_not_accepted), a keyword " <>
           "lane asked of a client_embedded corpus (keyword_lane_unavailable), an " <>
           "unknown lane (invalid_lanes), or a malformed, wrong-length or " <>
           "out-of-float32-range query_vector (invalid_query_vector, " <>
           "query_vector_dimension_mismatch, query_vector_out_of_range)", "application/json",
         Schemas.ErrorResponse},
      429 =>
        {"Rate limited (code rate_limited), or BOTH lanes shed by the per-tenant " <>
           "heavy-read gate (code heavy_read_overloaded, with Retry-After)", "application/json",
         Schemas.RateLimitError},
      502 =>
        {"Every lane attempted failed and none of them was a shed heavy read (code " <>
           "semantic_lane_unavailable, details.reason naming the bounded embedding " <>
           "failure tag). Reachable when the semantic lane is the only lane attempted — " <>
           "asked for by lanes:[semantic], or by a client_embedded corpus, which has no " <>
           "other lane.", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/corpora/:id/search"
  def search(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      [limit: to_int(Map.get(params, "limit")), lanes: Map.get(params, "lanes")]
      |> Enum.reject(&is_nil(elem(&1, 1)))

    case run_search(tenant_id, id, params, opts) do
      {:ok, result} -> json(conn, %{data: result.results, meta: result.meta})
      {:error, reason} -> handle_search_error(conn, reason)
    end
  end

  # A `query_vector` names the mode B path; the MODE decides whether it is accepted, so a
  # vector sent to a server_embedded corpus is refused by name rather than embedded or
  # ignored.
  #
  # Dispatch is on the VALUE, never on the key's presence. Emitting `null` for an absent
  # optional is ordinary client serialization (Go's encoding/json without omitempty,
  # `json.dumps({"query_vector": None})`, most generated clients), and matching the key
  # sent such a request down the mode B path to be refused with
  # `query_vector_not_accepted` — a message telling the caller to send the `query` it had
  # already sent. The mirror case, BOTH given, used to silently drop `query`; the request
  # schema says exactly one, so it is refused by name instead of one being preferred.
  defp run_search(tenant_id, id, params, opts) do
    query = Map.get(params, "query")
    vector = Map.get(params, "query_vector")

    cond do
      given?(query) and given?(vector) -> {:error, :ambiguous_query}
      given?(vector) -> Search.search_vector(tenant_id, id, vector, opts)
      true -> Search.search(tenant_id, id, query, opts)
    end
  end

  # A blank string is ABSENT for dispatch purposes, for the same serialization reason a
  # null is: a client without omitempty sends `query: ""` alongside a real vector. An
  # empty ARRAY is present — it is a malformed vector, and `invalid_query_vector` says
  # more than routing it to the query lane would.
  defp given?(nil), do: false
  defp given?(value) when is_binary(value), do: String.trim(value) != ""
  defp given?(_value), do: true

  defp handle_search_error(conn, :empty_query),
    do: error(conn, 422, "empty_query", "A query string is required.")

  defp handle_search_error(conn, :query_too_long),
    do: error(conn, 422, "query_too_long", query_too_long_message())

  # NOT an empty 200. An agent reads an empty result set as an empty corpus, so every
  # mode mismatch names the remedy instead.
  defp handle_search_error(conn, :query_string_not_accepted) do
    error(
      conn,
      422,
      "query_string_not_accepted",
      "This corpus is client_embedded: it stores vectors loopctl did not make and cannot " <>
        "read, so the server cannot embed a query for it. Send query_vector — a vector " <>
        "from the same local pipeline that produced the stored ones, at this corpus's dim."
    )
  end

  defp handle_search_error(conn, :query_vector_not_accepted) do
    error(
      conn,
      422,
      "query_vector_not_accepted",
      "This corpus is server_embedded: loopctl embeds the query with the corpus's own " <>
        "pinned model. Send query instead of query_vector."
    )
  end

  defp handle_search_error(conn, :keyword_lane_unavailable) do
    error(
      conn,
      422,
      "keyword_lane_unavailable",
      "This corpus is client_embedded, so it is SEMANTIC-ONLY: loopctl never received " <>
        "the chunk text and has nothing to index for a keyword lane. Ask for the semantic " <>
        "lane, or omit lanes entirely."
    )
  end

  defp handle_search_error(conn, {:invalid_lanes, received}) do
    error(
      conn,
      422,
      "invalid_lanes",
      "lanes must be a non-empty array drawn from #{inspect(@search_lanes)}.",
      %{received: inspect(received)}
    )
  end

  defp handle_search_error(conn, :invalid_query_vector) do
    error(
      conn,
      422,
      "invalid_query_vector",
      "query_vector must be a non-empty array of numbers at this corpus's dim."
    )
  end

  defp handle_search_error(conn, {:query_vector_dimension_mismatch, got, expected}) do
    error(
      conn,
      422,
      "query_vector_dimension_mismatch",
      "query_vector has #{got} dimensions but this corpus is pinned at #{expected}. " <>
        "Embed the query with the same local model that produced the stored vectors.",
      %{received_dim: got, corpus_dim: expected}
    )
  end

  defp handle_search_error(conn, {:query_vector_out_of_range, index}) do
    error(
      conn,
      422,
      "query_vector_out_of_range",
      "query_vector[#{index}] is outside the range pgvector's float32 element type can " <>
        "represent (magnitude at most #{@float32_max}). Postgres refuses such a value, so " <>
        "it is refused here rather than reaching the database as an unactionable error.",
      %{index: index}
    )
  end

  # The lanes that ran all failed AND none of them was the shed heavy read, which is only
  # reachable when the semantic lane was asked for alone. There is no degraded answer to
  # give, and the raw provider reason must never reach the FallbackController — it has no
  # clause for one and would answer 500 instead of a code the caller can branch on.
  defp handle_search_error(conn, {:semantic_lane_unavailable, reason}) do
    error(
      conn,
      502,
      "semantic_lane_unavailable",
      "The semantic lane could not run and it was the only lane attempted, so there is no " <>
        "degraded answer to return. Retry; on a server_embedded corpus, omitting lanes " <>
        "lets the keyword lane answer while the embedding path is unavailable.",
      %{reason: reason}
    )
  end

  defp handle_search_error(conn, :ambiguous_query) do
    error(
      conn,
      422,
      "ambiguous_query",
      "Send exactly one of query (server_embedded) or query_vector (client_embedded). " <>
        "Both arrived non-empty, and silently preferring one would answer a search the " <>
        "caller did not ask for."
    )
  end

  defp handle_search_error(_conn, reason), do: {:error, reason}

  # --- error rendering ---

  # REFUSED, never dropped. Accepting the item and ignoring the text would leave the
  # client believing loopctl holds text it never received — and therefore believing the
  # keyword lane works on a corpus that has none.
  defp handle_index_error(conn, {:text_not_accepted, index}) do
    error(
      conn,
      422,
      "text_not_accepted",
      "chunks[#{index}] carries text, but this corpus is client_embedded: it has no text " <>
        "lane and loopctl must never receive the content. Send only {source_ref, locator, " <>
        "vector, content_hash, ordinal, snippet?}.",
      %{index: index}
    )
  end

  # Names BOTH numbers, at the boundary, so the caller does not meet the
  # document_chunk_embeddings_dim_matches_vector CHECK as a raw Postgrex 500.
  defp handle_index_error(conn, {:vector_dimension_mismatch, index, got, expected}) do
    error(
      conn,
      422,
      "vector_dimension_mismatch",
      "chunks[#{index}] carries a #{got}-dimension vector but this corpus is pinned at " <>
        "#{expected}. The dimension is pinned at creation; re-dimensioning a corpus is " <>
        "delete-and-re-index by design.",
      %{index: index, received_dim: got, corpus_dim: expected}
    )
  end

  # `Pgvector.Ecto.Vector` DISCARDS an out-of-float32-range element on cast rather than
  # erroring, so without this the item reaches the changeset one element short and the
  # request fails as a 500 corpus_write_failed naming numbers the caller never sent.
  defp handle_index_error(conn, {:vector_out_of_range, index, at}) do
    error(
      conn,
      422,
      "vector_out_of_range",
      "chunks[#{index}].vector[#{at}] is outside the range pgvector's float32 element " <>
        "type can represent (magnitude at most #{@float32_max}). Re-embed with a pipeline " <>
        "that emits float32-representable values.",
      %{index: index, element_index: at}
    )
  end

  defp handle_index_error(conn, {:snippets_not_allowed, index}) do
    error(
      conn,
      422,
      "snippets_not_allowed",
      "chunks[#{index}] carries a snippet, but this corpus forbids them " <>
        "(allow_snippets is false — the default for a client_embedded corpus, since a " <>
        "snippet IS text the server would then hold). Create a corpus with " <>
        "allow_snippets true if you want readable results.",
      %{index: index}
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

  # Its OWN code, and it ECHOES what arrived. Folded into source_complete_not_carried
  # this answered "you do not carry that source" with an EMPTY missing list to a request
  # that plainly did carry it — both halves false, and no way for the caller to learn the
  # real fault is the type.
  defp handle_index_error(conn, {:source_complete_invalid, received}) do
    error(
      conn,
      422,
      "source_complete_invalid",
      "source_complete must be a LIST whose members are either a source_ref string or " <>
        "an object with a source_ref and a locators array declaring that source's " <>
        "complete locator set.",
      %{received: inspect(received)}
    )
  end

  defp handle_index_error(conn, {:prune_exceeds_carried, source_ref, pruned, carried}) do
    error(
      conn,
      422,
      "prune_exceeds_carried",
      "Naming #{source_ref} in source_complete without a locator manifest would delete " <>
        "#{pruned} stored chunks while this request carries only #{carried} for it, so the " <>
        "whole request was rolled back and nothing changed. A bare name asserts that what " <>
        "you sent IS the whole document; if it is (you are removing most of it) or if this " <>
        "is the last batch of a split document, name the source as an object and declare " <>
        "its complete locators array instead.",
      %{source_ref: source_ref, would_prune: pruned, carried: carried}
    )
  end

  defp handle_index_error(conn, {:source_manifest_too_large, source_ref, max}) do
    error(
      conn,
      422,
      "source_manifest_too_large",
      "A source_complete manifest declares at most #{max} locators.",
      %{source_ref: source_ref, max_locators: max}
    )
  end

  # A manifest that omits a locator the SAME request carries would have the transaction
  # write that chunk and delete it again, silently losing the write the caller just made.
  defp handle_index_error(conn, {:source_manifest_omits_carried, source_ref, omitted}) do
    error(
      conn,
      422,
      "source_manifest_omits_carried",
      "The source_complete manifest for #{source_ref} omits locators this request carries " <>
        "for it, so those chunks would be written and immediately deleted. A manifest " <>
        "declares the source's COMPLETE chunk set, which includes everything in this batch.",
      %{source_ref: source_ref, omitted: Enum.map(omitted, &inspect/1)}
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

  defp query_too_long_message,
    do: "The query is longer than #{@max_query_chars} characters."

  # States the rule the code ENFORCES, including the one that makes a document larger
  # than the ceiling reconcilable at all: the completing batch names the source WITH its
  # full locator manifest, so the chunks the earlier batches wrote are kept rather than
  # deleted.
  defp batch_too_large_message(max) do
    "A batch carries at most #{max} chunks. Split the document across several requests. " <>
      "To reconcile it, name it in source_complete on the batch that COMPLETES it as an " <>
      "object carrying its source_ref and its whole locators array, so the chunks the " <>
      "earlier batches wrote are kept and only surplus chunks are deleted. A " <>
      "bare source_ref name reconciles against that one request alone, which is correct " <>
      "only for a document that fits in one batch."
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
      bucket = "corpus_index:tenant:#{tenant_id(conn)}"
      gate(conn, charge_items(bucket, ingest_limit(conn), max(items, 1)))
    end
  end

  defp rate_limit_search(conn, _opts) do
    bucket = "corpus_search:tenant:#{tenant_id(conn)}"

    gate(conn, RateLimiter.within_limit?(bucket, @rate_limit_window_ms, search_limit(conn)))
  end

  # Bucketed per TENANT, not per key: indexing and searching a corpus are TENANT
  # resources (one provider bill, one HeavyRead budget), and a per-key bucket would let
  # a tenant multiply its own ceiling by minting keys — which, under the v2 dispatch
  # pattern, it does routinely (one ephemeral key per dispatch).
  defp tenant_id(conn), do: conn.assigns.current_api_key.tenant_id

  defp gate(conn, true), do: conn

  defp gate(conn, false) do
    retry_after = max(1, window_reset_at() - System.system_time(:second))

    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{error: %{status: 429, code: "rate_limited", message: "Rate limit exceeded"}})
    |> halt()
  end

  # AC-43.2.7's per-ITEM charge. `check_rate/3` increments by ONE per call, so N items
  # cost N calls — and the FIRST call's post-increment count is the tenant's headroom,
  # which decides the rest of the batch before any of it is charged.
  #
  # Without that headroom read the loop charged item by item until it was denied
  # mid-batch, so a 200-chunk request with 140 tokens left spent all 140, wrote nothing,
  # and left the tenant unable to afford even a one-chunk request it could otherwise have
  # made. A refused batch now costs exactly ONE token — the same token every refused
  # request on every other bucket in this codebase spends, since `check_rate/3` increments
  # before it compares.
  defp charge_items(bucket, limit, items) do
    case consult(bucket, limit) do
      {:metered, count} -> charge_rest(bucket, limit, items, count)
      :unmetered -> true
      :denied -> false
    end
  end

  defp charge_rest(_bucket, limit, items, count) when items - 1 > limit - count, do: false
  defp charge_rest(_bucket, _limit, items, _count) when items <= 1, do: true

  defp charge_rest(bucket, limit, items, _count) do
    Enum.reduce_while(2..items, true, fn _charge, _acc ->
      case consult(bucket, limit) do
        :denied -> {:halt, false}
        _outcome -> {:cont, true}
      end
    end)
  end

  # One limiter round trip, normalised. `{:allow, 0}` is the Postgres impl's fail-open
  # SENTINEL, not a real count, so it is reported `:unmetered` and never fed to the
  # headroom arithmetic — read as a count it would refuse a batch the limiter never
  # actually measured.
  #
  # The METER is pinned away from `RateLimiter.Postgres` (see `index_meter/1`): with a
  # per-ITEM charge, one ordinary 200-chunk request was 200 SEQUENTIAL `AdminRepo`
  # upserts on ONE hot row, taken from the 3-connection BYPASSRLS pool that also carries
  # custody writes, BEFORE the request did any work — including for a batch that turned
  # out to be entirely unchanged and wrote nothing.
  defp consult(bucket, limit) do
    case index_meter(RateLimiter.impl()).check_rate(bucket, @rate_limit_window_ms, limit) do
      {:allow, count} when is_integer(count) and count > 0 -> {:metered, count}
      {:allow, _sentinel} -> :unmetered
      {:deny, _limit} -> :denied
      other -> fail_open(bucket, "limiter returned #{inspect(other)}")
    end
  rescue
    error -> fail_open(bucket, Exception.message(error))
  catch
    :exit, reason -> fail_open(bucket, "exit: #{inspect(reason)}")
    :throw, value -> fail_open(bucket, "throw: #{inspect(value)}")
  end

  defp fail_open(bucket, detail) do
    FailOpenLog.warn(:corpus, bucket, detail)
    :unmetered
  end

  @doc """
  The limiter implementation the per-ITEM index bucket charges against.

  Honours `RateLimiter.impl/0` except for ONE case: under `RATE_LIMITER=postgres` the
  limiter store IS `AdminRepo`, so a per-item charge turns one index request into up to
  #{@max_batch_size} sequential upserts on a single hot row, taken from the 3-connection
  BYPASSRLS pool that also carries custody writes — the failure mode
  `LoopctlWeb.KnowledgeIngestionController.fail_open_meter/1` pins away from for the same
  reason. The SEARCH bucket is charged once per request, in the same unit the shared
  buckets count, so it is NOT pinned and stays cluster-global.

  PUBLIC and a pure function of the configured impl so the pin is testable: in the test
  env `RateLimiter.impl/0` is always the Mox mock, so the `Postgres` clause would
  otherwise be dead code a later edit could invert with a green suite.
  """
  @spec index_meter(module()) :: module()
  def index_meter(RateLimiter.Postgres), do: RateLimiter.default_impl()
  def index_meter(impl), do: impl

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
