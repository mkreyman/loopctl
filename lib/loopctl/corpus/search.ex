defmodule Loopctl.Corpus.Search do
  @moduledoc """
  US-43.2 — `corpus_search`: two lanes, one fuser, and a POINTER rather than a body.

  A result is `{source_ref, locator, snippet, score, corpus_id, chunk_id}`. It NEVER
  carries the full chunk text: the agent is told page 47 of a named file and opens
  the file itself, which is what keeps the file the source of truth and the response
  small. The snippet is bounded by `max_snippet_chars/0`, the ONE attribute the
  controller's OpenAPI `maxLength` also reads.

  ## Two lanes, the article path's fuser

  Keyword runs over the `search_vector` generated column; semantic runs over the
  per-dimension HNSW index on `document_chunk_embeddings`. They are fused by
  `Loopctl.Knowledge.fuse_rrf/2` — the SAME Reciprocal Rank Fusion the article path
  uses, at the same `:knowledge_rrf_k` and the same tiebreak — called with an empty
  graph lane. Scores are therefore RANK-DERIVED and comparable only WITHIN one
  result set; there is no absolute floor to document or enforce.

  `meta.lanes` NAMES the lanes that actually ran, so a caller can tell a
  semantic-only or keyword-only result set from a fused one instead of inferring it
  from the shape of the results.

  ## The pool is sized against the CORPUS, not the tenant

  `corpus_id` is a SELECTIVE filter and a corpus is usually a small fraction of a
  tenant's chunks. It must NOT go on the index-ordered inner scan — a selective
  btree predicate or a join inside the top-k flips the planner off HNSW (the
  #170/#172 production shape). So it is applied on the OUTER query over the
  materialized pool, exactly as the article path applies status and visibility.

  That makes `corpus_id` a POST-ANN residual on top of the `tenant_id` residual the
  partial index already leaves (the index is partial on `(dim, live_denorm)` only),
  and `hnsw.iterative_scan` is default-off in production — so the inner limit is
  over-fetched (`side_table_inner_pool/1` times `@corpus_pool_multiplier`, and never
  below `VectorSearch.max_side_table_ef_search/0`) and `hnsw.ef_search` is raised in
  lockstep. An HNSW scan returns ~`ef_search` nodes regardless of LIMIT, so the
  over-fetch is inert without that, and an inner limit BELOW the configured ef ceiling
  leaves breadth the deployment already allows unused.

  ## An under-filled semantic lane SAYS SO

  The over-fetch bounds the hazard; it cannot remove it. `hnsw.ef_search` is capped by
  `:side_table_max_ef_search`, so a tenant whose nearest ~`ef_search` chunk vectors all
  belong to ANOTHER corpus still yields few rows — or none — for the target. That case
  used to answer `{:ok, []}` with the lane still named in `meta.lanes`, which a caller
  reads as "this corpus has nothing" rather than "the scan did not reach it".

  So a short lane is checked against the corpus itself with a BOUNDED probe: a corpus
  holding no more chunks than the lane returned did not under-fill, it is simply that
  small. One that holds more did, and `meta.semantic_under_filled` says so — the corpus
  tier's form of the article path's under-fill disclosure. Narrowing the query, or a
  corpus of its own for the material, is what a caller does about it.

  ## Not a recall surface

  `corpus_search` must NEVER be wired into `/api/v1/recall`. That hook injects into
  every repo's session, and verbatim spec chunks there are precisely the pollution
  the separate tables exist to prevent.
  """

  import Ecto.Query

  alias Loopctl.Corpus
  alias Loopctl.Corpus.Corpus, as: CorpusRow
  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Search.Regconfig

  # The snippet ceiling, read from the SCHEMA that stores the column. The truncation
  # below, `DocumentChunk.changeset/2`'s `validate_length` on the write, and the
  # controller's OpenAPI `maxLength` on BOTH the request and the response all read this
  # one number, so a documented bound can never outrun an enforced one (AC-43.2.4).
  @max_snippet_chars DocumentChunk.max_snippet_chars()

  @default_limit 10
  @max_limit 50
  @max_query_chars 500

  # Per-lane candidate pool before fusion.
  @lane_pool 50

  # Extra inner-ANN over-fetch for the corpus residual, ON TOP of the side table's
  # own `side_table_over_fetch/0`. The article path's over-fetch offsets a
  # status/visibility trim; this one additionally offsets `corpus_id`, which can
  # discard almost the whole pool when the target corpus is a small minority of the
  # tenant's chunks. That is the "silently empty search" case.
  @corpus_pool_multiplier 4

  # Keyword and semantic weigh equally, as they do on the article path. The graph
  # lane is EMPTY in this tier (there is no chunk-link graph), and an empty lane
  # contributes nothing at any weight — it is passed so the fuser is called at its
  # real lane-list shape rather than a corpus-specific one.
  @keyword_weight 0.5
  @semantic_weight 0.5
  @graph_weight 0.0

  @doc "The maximum snippet length a search result may carry."
  @spec max_snippet_chars() :: pos_integer()
  def max_snippet_chars, do: @max_snippet_chars

  @doc "The maximum number of ranked results one search may return."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc "The maximum query length accepted."
  @spec max_query_chars() :: pos_integer()
  def max_query_chars, do: @max_query_chars

  @doc """
  Searches `corpus_id` (an id or a slug) for `query_string`.

  `opts`: `:limit` (default #{@default_limit}, clamped to #{@max_limit}).

  Returns `{:ok, %{results: [...], meta: %{lanes: [...], ...}}}`. Both lanes failing
  is the only case that returns `{:error, :heavy_read_overloaded}` — a semantic lane
  that cannot run (no embedding key, an embed failure, a shed heavy read) degrades to
  keyword-only and says so in `meta`, the way semantic article search does. A semantic
  lane that RAN but could not reach the whole corpus sets `meta.semantic_under_filled`.
  """
  @spec search(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
          | {:error,
             :not_found
             | :mode_mismatch
             | :empty_query
             | :query_too_long
             | :heavy_read_overloaded}
  def search(tenant_id, corpus_id, query_string, opts \\ []) when is_binary(tenant_id) do
    with {:ok, corpus} <- Corpus.get_corpus(tenant_id, corpus_id),
         :ok <- validate_mode(corpus),
         {:ok, query_string} <- validate_query(query_string) do
      limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

      run(tenant_id, corpus, query_string, limit)
    end
  end

  # The SAME refusal `Loopctl.Corpus.Indexer.validate_mode/1` gives the ingest verb. A
  # client_embedded corpus holds vectors the server did not make and cannot read: without
  # this clause a search against one embedded the query on the tenant's own key, billed
  # the provider call, and answered 200 with an empty set — one half of the surface
  # refusing mode B with a coded 422 while the other half charged for a query the corpus
  # can never serve. Both halves refuse it until US-43.3 defines mode B's retrieval
  # contract.
  defp validate_mode(%CorpusRow{mode: :server_embedded}), do: :ok
  defp validate_mode(%CorpusRow{}), do: {:error, :mode_mismatch}

  defp run(tenant_id, corpus, query_string, limit) do
    keyword = keyword_lane(tenant_id, corpus, query_string)
    semantic = semantic_lane(tenant_id, corpus, query_string)

    case {keyword, semantic} do
      {{:error, reason}, {:error, _}} ->
        {:error, reason}

      _ ->
        {:ok, fuse(corpus, keyword, semantic, limit)}
    end
  end

  defp fuse(corpus, keyword, semantic, limit) do
    kw_results = lane_results(keyword)
    sem_results = lane_results(semantic)

    results =
      Knowledge.fuse_rrf(
        [
          {kw_results, @keyword_weight},
          {sem_results, @semantic_weight},
          {[], @graph_weight}
        ],
        []
      )
      |> Enum.take(limit)
      |> Enum.map(&render(&1, corpus))

    %{results: results, meta: meta(corpus, keyword, semantic, limit)}
  end

  defp lane_results({:ok, results}), do: results
  defp lane_results({:partial, results}), do: results
  defp lane_results({:error, _reason}), do: []

  defp meta(corpus, keyword, semantic, limit) do
    lanes =
      [{"keyword", keyword}, {"semantic", semantic}]
      |> Enum.reject(&match?({_name, {:error, _}}, &1))
      |> Enum.map(&elem(&1, 0))

    %{
      corpus_id: corpus.id,
      corpus_slug: corpus.slug,
      limit: limit,
      # NAMED, never inferred: a caller must be able to tell a fused result set from
      # a single-lane one without guessing from the results (AC-43.2.5).
      lanes: lanes,
      search_mode: search_mode(lanes),
      # Rank-derived (RRF), so comparable WITHIN this result set only. Deliberately
      # no absolute floor is published: changing the fusion strategy would silently
      # invalidate any threshold a caller had written down.
      score_basis: "rrf",
      snippet_max_chars: @max_snippet_chars,
      allow_snippets: corpus.allow_snippets
    }
    |> maybe_put_reason(:keyword_unavailable_reason, keyword)
    |> maybe_put_reason(:semantic_unavailable_reason, semantic)
    |> maybe_put_under_fill(semantic)
  end

  # NAMED, never inferred, for the same reason `lanes` is: a lane that ran but could not
  # reach the whole corpus returns FEWER results, not an error, so nothing else in the
  # response distinguishes it from a corpus that genuinely holds nothing.
  defp maybe_put_under_fill(meta, {:partial, _results}),
    do: Map.put(meta, :semantic_under_filled, true)

  defp maybe_put_under_fill(meta, _semantic), do: meta

  defp search_mode(["keyword", "semantic"]), do: "combined"
  defp search_mode(["keyword"]), do: "keyword_only"
  defp search_mode(["semantic"]), do: "semantic_only"
  defp search_mode(_lanes), do: "none"

  defp maybe_put_reason(meta, key, {:error, reason}), do: Map.put(meta, key, to_tag(reason))
  defp maybe_put_reason(meta, _key, _lane), do: meta

  defp to_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp to_tag(_reason), do: "embedding_error"

  # --- keyword lane ---

  # The regconfig is bound as a `?::text::regconfig` PARAMETER and must be the same
  # one `20260827160000_add_search_vector_to_document_chunks.exs` baked into the
  # generated column. The `::text::` is required: a bare `?::regconfig` makes Postgrex
  # describe the param as the regconfig OID and reject the string name at encode time.
  defp keyword_lane(tenant_id, corpus, query_string) do
    regconfig = Regconfig.get()

    query =
      from(c in DocumentChunk,
        where: c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id,
        where:
          fragment(
            "search_vector @@ websearch_to_tsquery(?::text::regconfig, ?)",
            ^regconfig,
            ^query_string
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank_cd(search_vector, websearch_to_tsquery(?::text::regconfig, ?))",
              ^regconfig,
              ^query_string
            )
        ],
        limit: ^@lane_pool,
        select: %{
          id: c.id,
          corpus_id: c.corpus_id,
          source_ref: c.source_ref,
          locator: c.locator,
          # The ENFORCING truncation, and the ONLY one: `left/2` in the SELECT bounds
          # the value in Postgres, so a 40 KB chunk is never shipped out of the
          # database at all — a second slice in Elixir would be unreachable, which is
          # to say dead. It reads the same `@max_snippet_chars` the OpenAPI
          # `maxLength` does, so the documented bound and the enforced bound are the
          # same number by construction.
          snippet: fragment("left(coalesce(?, ?), ?)", c.snippet, c.text, ^@max_snippet_chars),
          relevance_score:
            fragment(
              "ts_rank_cd(search_vector, websearch_to_tsquery(?::text::regconfig, ?))",
              ^regconfig,
              ^query_string
            )
        }
      )

    read(tenant_id, query, heavy_opts())
  end

  # --- semantic lane ---

  defp semantic_lane(tenant_id, corpus, query_string) do
    with {:ok, vector} <- embed_query(tenant_id, corpus, query_string),
         :ok <- validate_dimension(vector, corpus.dim) do
      ann(tenant_id, corpus, vector)
    end
  end

  # The corpus's OWN pinned model — never the tenant's configured one, which governs
  # articles and memories and would produce a vector that disagrees with every stored
  # chunk vector in this corpus.
  defp embed_query(tenant_id, corpus, query_string) do
    case Knowledge.generate_embedding(tenant_id, query_string,
           embedding_model: corpus.embedding_model
         ) do
      {:ok, vector} -> {:ok, vector}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_dimension(vector, dim) when length(vector) == dim, do: :ok
  defp validate_dimension(_vector, _dim), do: {:error, :dimension_mismatch}

  defp ann(tenant_id, corpus, vector) do
    inner_pool = inner_pool()

    inner =
      DocumentChunkEmbedding
      |> VectorSearch.index_safe_dimension_knn_base(tenant_id, vector, corpus.dim, inner_pool)
      |> select([e], %{document_chunk_id: e.document_chunk_id})
      |> VectorSearch.put_dimension_distance(corpus.dim, vector)

    query =
      from(p in subquery(inner),
        join: c in DocumentChunk,
        on: c.id == p.document_chunk_id and c.tenant_id == ^tenant_id,
        where: c.corpus_id == ^corpus.id,
        order_by: [asc: p.distance],
        limit: ^@lane_pool,
        select: %{
          id: c.id,
          corpus_id: c.corpus_id,
          source_ref: c.source_ref,
          locator: c.locator,
          snippet: fragment("left(coalesce(?, ?), ?)", c.snippet, c.text, ^@max_snippet_chars),
          similarity_score: fragment("GREATEST(0, 1 - ?)", p.distance)
        }
      )

    opts =
      Keyword.put(
        heavy_opts(),
        :hnsw_ef_search,
        VectorSearch.side_table_ef_search(inner_pool)
      )

    case read(tenant_id, query, opts) do
      {:ok, rows} when length(rows) < @lane_pool -> classify_fill(tenant_id, corpus, rows)
      other -> other
    end
  end

  # `side_table_ef_search/1` is `min(inner_pool, max_side_table_ef_search())`, and an HNSW
  # scan inspects ~`ef_search` graph nodes regardless of the LIMIT — so an inner pool
  # BELOW that ceiling asks for less breadth than the deployment already permits, which
  # is exactly the breadth the `corpus_id` residual spends. The floor makes the pool track
  # the CONFIGURED ceiling instead of a bare constant.
  defp inner_pool do
    max(
      VectorSearch.side_table_inner_pool(@lane_pool) * @corpus_pool_multiplier,
      VectorSearch.max_side_table_ef_search()
    )
  end

  # A short lane is either a small corpus or a residual that emptied a saturated pool, and
  # the two are indistinguishable from the result set alone. The BOUNDED probe below
  # separates them: it counts the corpus's chunks only up to the lane pool, so it is a
  # `LIMIT #{@lane_pool}` index scan and never an aggregate over the corpus. A probe that
  # is itself shed leaves the lane reported as complete rather than inventing a
  # degradation from a failed measurement.
  defp classify_fill(tenant_id, corpus, rows) do
    case corpus_chunks_up_to(tenant_id, corpus, @lane_pool) do
      {:ok, available} when available > length(rows) -> {:partial, rows}
      _outcome -> {:ok, rows}
    end
  end

  defp corpus_chunks_up_to(tenant_id, corpus, cap) do
    query =
      from(c in DocumentChunk,
        where: c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id,
        limit: ^cap,
        select: 1
      )

    case read(tenant_id, query, heavy_opts()) do
      {:ok, rows} -> {:ok, length(rows)}
      error -> error
    end
  end

  # --- shared plumbing ---

  # `on_overload: :tag` so a shed heavy read comes back as a tagged error the caller
  # maps to a degraded lane, rather than raising a 429 through to the agent.
  defp heavy_opts, do: [{:on_overload, :tag} | HeavyRead.opts(:corpus_search)]

  defp read(tenant_id, query, opts) do
    case HeavyRead.all(tenant_id, query, opts) do
      {:error, reason} -> {:error, reason}
      rows -> {:ok, rows}
    end
  end

  # `allow_snippets` is a corpus POLICY, so it is honoured HERE, on the read — the one
  # place a snippet can reach a caller. Suppressing it at write instead would contradict
  # US-43.1, which deliberately keeps the flag castable and lets an explicit caller value
  # win over the mode-derived default. A corpus that says it serves no snippets serves
  # none: the key is still present and null, so a client reads a pointer rather than
  # inferring one from a missing field.
  defp render(result, %CorpusRow{allow_snippets: false}) do
    result |> render_pointer() |> Map.put(:snippet, nil)
  end

  defp render(result, %CorpusRow{}) do
    result |> render_pointer() |> Map.put(:snippet, result[:snippet])
  end

  defp render_pointer(result) do
    %{
      chunk_id: result.id,
      corpus_id: result.corpus_id,
      source_ref: result.source_ref,
      locator: result.locator,
      score: result.final_score
    }
  end

  defp validate_query(query_string) when is_binary(query_string) do
    trimmed = String.trim(query_string)

    cond do
      trimmed == "" -> {:error, :empty_query}
      String.length(trimmed) > @max_query_chars -> {:error, :query_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp validate_query(_query_string), do: {:error, :empty_query}

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end
