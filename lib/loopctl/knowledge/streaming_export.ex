defmodule Loopctl.Knowledge.StreamingExport do
  @moduledoc """
  Bounded-memory, fail-closed, pool-safe streaming knowledge export (US-27.16).

  This is the shared CORE behind both the Obsidian and OKF exports: it walks a
  tenant's published articles via the US-27.9a keyset cursor and emits one archive
  entry per article into a streamed `.tar.gz`, holding at most `chunk_size`
  articles in memory at any time. The per-format file content/layout is the only
  thing that differs and is delegated to a `Loopctl.Knowledge.StreamingExport.Format`
  implementation.

  ## Why keyset pages, not `Repo.stream` (AC-27.16.1/.6)

  `Repo.stream` requires ONE enclosing transaction held for the WHOLE client-paced
  download — pinning one of the few BYPASSRLS heavy-read connections AND `xmin`
  (blocking vacuum on a churning 76k-row table) for minutes. Instead we page with
  the keyset cursor on `(inserted_at, id)`: each page is a SHORT
  `Loopctl.HeavyRead.all/3` read — a brief per-read `SET LOCAL statement_timeout`
  transaction (US-27.13) that COMMITS and RELEASES the connection + `xmin` between
  pages, NOT one long-held transaction across the whole download. The
  walk is drift-free (seeks the stable unique tuple, never an OFFSET).

  ## Tenant scoping under BYPASSRLS (AC-27.16.5)

  Every page query AND the per-page link preload run through `Loopctl.HeavyRead`,
  whose structural guard rejects any query not conjunctively scoped to the passed
  `tenant_id`. The page WHERE is byte-identical to the legacy
  `export_base_query/2` (tenant_id + status=:published + `project_id IS NULL OR
  project_id == ^pid`), so the streamed bundle's id-set equals the legacy
  `fetch_published_for_export/2` set for the same `(tenant, project)`.

  ## Bounded link fan-out (AC-27.16.3)

  A dense-hub article can have thousands of links; materializing them all into one
  entry would blow the per-entry memory bound. So the per-page link preload caps
  each article's neighbor list at `max_links_per_article/0` (mirroring the
  `@full_content_byte_budget`/graph-cap precedents). The cap is applied in SQL
  (`LIMIT` per side) so the rows are never even fetched.

  ## Fail-closed (AC-27.16.4)

  Streaming is driven through `Loopctl.Knowledge.StreamingExport.TarGz`. On any
  mid-stream error (Repo timeout, dropped connection, format crash) the writer is
  `abort/1`-ed — the tar end-of-archive marker and gzip trailer are NEVER written,
  so a consumer detects truncation. The error is mapped through `LoopctlWeb.DBError`
  semantics by the controller so no SQL/params/vector-literals/stack-traces reach
  the partial bytes.

  ## Per-tenant heavy-read weight + overload disposition (US-37.5)

  Every export scan is a genuinely HEAVY, long (60s) read, so it is stamped with the
  `:export` endpoint (`export_read_opts/0`) — weighted `heavy` (2) by
  `Loopctl.HeavyRead.TenantGate` (an unweighted read defaults to LIGHT, letting a
  tenant hold more concurrent export slots than the cost model intends). The reads
  keep HeavyRead's default `on_overload: :raise`, so when a tenant is over its
  per-tenant in-flight slice an export scan sheds by RAISING
  `Loopctl.HeavyRead.OverloadedError`. That is a DELIBERATE fail-closed disposition:
  the raise is caught by the same page/aggregate/link `rescue` clauses that fail
  closed on any DB error (`safe_fetch_page/5`, `emit_index/4`, `emit_article_page/5`)
  — the writer is aborted, the consumer detects truncation, and the export is
  re-run once the tenant's heavy-read load subsides. (Since the scan is released
  between keyset pages, an export mostly coexists; a shed only occurs when the tenant
  is ALREADY saturating its slice — failing that one export is the correct fairness
  outcome.)
  """

  import Ecto.Query

  require Logger

  alias Loopctl.HeavyRead
  alias Loopctl.KeysetSeek
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.StreamingExport.TarGz

  @default_chunk_size 200
  @default_max_links_per_article 100
  @default_max_stream_duration_ms :timer.minutes(10)

  # Export pages/aggregates/link preloads get a longer per-read timeout than fast reads
  # (60s vs the 10s fast-read default) — a single page (even a dense graph at prod
  # scale) completes well under 60s, so this only prevents a legitimately slow page
  # timing out mid-export. The `:export` endpoint makes `Loopctl.HeavyRead.TenantGate`
  # weight these HEAVY (US-37.5) — an unstamped read would default to LIGHT and let a
  # tenant hold more concurrent export slots than the heavy-scan cost model intends.
  @export_statement_timeout_ms 60_000
  @export_endpoint :export

  @doc "Configured keyset page size (articles held in memory per page). Tunable for tests."
  @spec chunk_size() :: pos_integer()
  def chunk_size, do: Application.get_env(:loopctl, :export_chunk_size, @default_chunk_size)

  @doc """
  Per-article link-list cap (AC-27.16.3): the max neighbors rendered per article so
  a dense hub can't materialize an unbounded entry. Applied in SQL per side.
  """
  @spec max_links_per_article() :: pos_integer()
  def max_links_per_article,
    do:
      Application.get_env(:loopctl, :export_max_links_per_article, @default_max_links_per_article)

  @doc """
  Soft ceiling (ms) on a single streamed export's wall-clock (AC-27.16.2/.6): a
  documented TIME budget, not an article-count cap. Exceeding it aborts the stream
  fail-closed.

  NOTE: the budget is checked at PAGE BOUNDARIES (between keyset pages), not
  mid-page — so the effective wall-clock can overshoot by at most ONE page's
  processing time (≤ `chunk_size` articles). Per-statement runaway is bounded
  separately by the heavy-read pool's `statement_timeout`. Tunable; defaults to 10
  minutes.
  """
  @spec max_stream_duration_ms() :: pos_integer()
  def max_stream_duration_ms,
    do:
      Application.get_env(
        :loopctl,
        :export_max_stream_duration_ms,
        @default_max_stream_duration_ms
      )

  @typedoc "The emit fun threading a `Plug.Conn` (or any caller state) through chunk writes."
  @type emit_fun :: (iodata() -> {:ok, term()} | {:error, term()})

  @doc """
  Streams a `.tar.gz` export of `tenant_id`'s published articles in `format`,
  flushing compressed chunks via `emit` (which threads the caller's conn/state).

  ## Options

  - `:project_id` — when set, includes tenant-wide (nil project) + project articles
    (the `project_id IS NULL OR project_id == ^pid` disjunction).
  - `:conn` — the initial threaded value handed to `emit` (a `Plug.Conn`); the
    final value is returned on success.
  - `:chunk_size` — override the page size (default `chunk_size/0`).

  ## Returns

  - `{:ok, conn}` — the archive was fully written (end-of-archive + gzip trailer);
    `conn` is the final threaded value.
  - `{:error, reason}` — a mid-stream failure; the archive was `abort/1`-ed WITHOUT
    a valid end-of-archive (fail-closed). The caller MUST treat the response as
    truncated (it already committed `200` via `send_chunked`).
  """
  @spec stream(Ecto.UUID.t(), module(), emit_fun(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def stream(tenant_id, format, emit, opts \\ [])
      when is_binary(tenant_id) and is_atom(format) and is_function(emit, 1) do
    project_id = Keyword.get(opts, :project_id)
    conn = Keyword.get(opts, :conn)
    page_size = Keyword.get(opts, :chunk_size, chunk_size())
    deadline = System.monotonic_time(:millisecond) + max_stream_duration_ms()

    case TarGz.init(emit, conn) do
      {:ok, writer} ->
        run(tenant_id, format, writer, project_id, page_size, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run(tenant_id, format, writer, project_id, page_size, deadline) do
    position =
      if function_exported?(format, :index_position, 0),
        do: format.index_position(),
        else: :prelude

    with {:ok, writer} <-
           maybe_emit_index(writer, tenant_id, format, project_id, :prelude, position),
         {:ok, writer} <-
           stream_article_pages(writer, tenant_id, format, project_id, page_size, deadline, nil),
         {:ok, writer} <-
           maybe_emit_index(writer, tenant_id, format, project_id, :postlude, position),
         {:ok, conn} <- TarGz.finish(writer) do
      {:ok, conn}
    else
      {:error, reason, writer} ->
        # Mid-stream failure with a live writer (from index/page emission): ABORT
        # without a valid end-of-archive so the consumer detects truncation
        # (fail-closed). abort/1 frees the zlib + ETS resources.
        TarGz.abort(writer)
        {:error, reason}

      {:error, reason} ->
        # 2-tuple error from TarGz.finish/1 (a transport error during the FINAL
        # flush): finish/1 already freed its resources on the error path (#9), so we
        # just propagate. The bytes already sent lack a valid end-of-archive →
        # fail-closed by construction (we never wrote one).
        {:error, reason}
    end
  end

  # --- index (cheap aggregate, no bodies) ---

  defp maybe_emit_index(writer, _tid, _fmt, _pid, slot, position) when slot != position,
    do: {:ok, writer}

  defp maybe_emit_index(writer, tenant_id, format, project_id, _slot, _position) do
    aggregate = category_aggregate(tenant_id, project_id)
    entries = format.index_entries(aggregate)
    emit_entries(writer, entries)
  rescue
    # A DB error building the cheap aggregate (or a format crash) fails closed too.
    e -> {:error, e, writer}
  end

  # GROUP BY category COUNT — never loads a body (AC-27.16 `_index.md` requirement).
  defp category_aggregate(tenant_id, project_id) do
    query =
      tenant_id
      |> base_query(project_id)
      |> group_by([a], a.category)
      |> select([a], %{category: a.category, count: count(a.id)})

    # Export aggregations use the same extended 60s timeout + heavy `:export` weight as
    # export pages. A shed (OverloadedError) is caught by `emit_index/4`'s rescue → fail-closed.
    HeavyRead.all(tenant_id, query, export_read_opts())
  end

  # --- article pages (keyset walk) ---

  defp stream_article_pages(writer, tenant_id, format, project_id, page_size, deadline, cursor) do
    # Hard wall-clock budget (AC-27.16.2/.6): abort fail-closed if the export runs
    # past `max_stream_duration_ms/0`.
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :export_time_budget_exceeded, writer}
    else
      stream_next_page(writer, tenant_id, format, project_id, page_size, deadline, cursor)
    end
  end

  defp stream_next_page(writer, tenant_id, format, project_id, page_size, deadline, cursor) do
    # A mid-stream DB error (timeout, dropped connection) raised by the keyset read
    # is turned into an explicit `{:error, reason, writer}` so `run/6` ABORTS the
    # writer (no end-of-archive — fail-closed, AC-27.16.4) rather than letting the
    # exception propagate past the already-committed 200 and abandon the writer to GC.
    case safe_fetch_page(tenant_id, project_id, page_size, cursor, writer) do
      {:ok, page, next_cursor} ->
        emit_page_then_continue(
          writer,
          tenant_id,
          format,
          project_id,
          page_size,
          deadline,
          page,
          next_cursor
        )

      {:error, _reason, _writer} = err ->
        err
    end
  end

  defp safe_fetch_page(tenant_id, project_id, page_size, cursor, writer) do
    {page, next_cursor} = fetch_page(tenant_id, project_id, page_size, cursor)
    {:ok, page, next_cursor}
  rescue
    e -> {:error, e, writer}
  end

  defp emit_page_then_continue(
         writer,
         tenant_id,
         format,
         project_id,
         page_size,
         deadline,
         page,
         next_cursor
       ) do
    case emit_article_page(writer, tenant_id, format, project_id, page) do
      {:ok, writer} when is_nil(next_cursor) ->
        {:ok, writer}

      {:ok, writer} ->
        stream_article_pages(
          writer,
          tenant_id,
          format,
          project_id,
          page_size,
          deadline,
          next_cursor
        )

      {:error, _reason, _writer} = err ->
        err
    end
  end

  # One short keyset read: fetch page_size+1 to detect a next page without a COUNT,
  # released as soon as HeavyRead.all returns (no long-held transaction).
  defp fetch_page(tenant_id, project_id, page_size, cursor) do
    query =
      tenant_id
      |> base_query(project_id)
      |> apply_keyset_seek(cursor)
      |> order_by([a], asc: a.inserted_at, asc: a.id)
      |> select([a], %{
        id: a.id,
        tenant_id: a.tenant_id,
        project_id: a.project_id,
        title: a.title,
        body: a.body,
        category: a.category,
        status: a.status,
        tags: a.tags,
        source_type: a.source_type,
        metadata: a.metadata,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at,
        # The retrieval tombstone. Projected because this streamed bundle is the DEFAULT
        # backup, and `OKF.suppression_frontmatter/1` reads these three off the row: absent
        # here, it silently emits nothing and the restored corpus carries no record that
        # anyone ever took the article out of retrieval.
        suppressed_at: a.suppressed_at,
        suppressed_by: a.suppressed_by,
        suppression_reason: a.suppression_reason
      })
      |> limit(^(page_size + 1))

    # Export pages carry the extended 60s per-read timeout + heavy `:export` weight
    # (see `export_read_opts/0`). A shed (OverloadedError) is caught by
    # `safe_fetch_page/5`'s rescue → fail-closed abort.
    rows = HeavyRead.all(tenant_id, query, export_read_opts())

    if length(rows) > page_size do
      page = Enum.take(rows, page_size)
      last = List.last(page)
      {page, {last.inserted_at, last.id}}
    else
      {rows, nil}
    end
  end

  defp emit_article_page(writer, _tid, _fmt, _pid, []), do: {:ok, writer}

  defp emit_article_page(writer, tenant_id, format, _project_id, page) do
    links_by_article = load_bounded_links(tenant_id, page)
    body_probe = body_probe()

    Enum.reduce_while(page, {:ok, writer}, fn row, {:ok, writer} ->
      article = to_article(row)
      {links, truncated?} = Map.get(links_by_article, row.id, {[], false})

      # Injected observation seam (`Loopctl.Knowledge.StreamingExport.BodyProbe`). The
      # production impl is a no-op; the bounded-memory scale gate injects a RETAINING probe
      # to prove that metric is load-bearing. Resolved once per page (see `body_probe/0`),
      # so this is a plain fun call per row — no config lookup, no behaviour dispatch.
      body_probe.(row.body)

      ctx = %{
        links: links,
        links_truncated: truncated?,
        project_id: row.project_id
      }

      entries = format.article_entries(article, ctx)

      case emit_entries(writer, entries) do
        {:ok, writer} -> {:cont, {:ok, writer}}
        {:error, reason, writer} -> {:halt, {:error, reason, writer}}
      end
    end)
  rescue
    e -> {:error, e, writer}
  end

  # Config-based DI (`CLAUDE.md`: behaviours + `Application.get_env`, never opts, never
  # `put_env` from a test). Production resolves to `NoopBodyProbe`; `config/test.exs`
  # points at a Mox mock whose DEFAULT stub is equally a no-op, so only the one scale test
  # that injects a retaining probe sees any retention.
  defp body_probe do
    Application.get_env(
      :loopctl,
      :streaming_export_body_probe,
      Loopctl.Knowledge.StreamingExport.NoopBodyProbe
    ).probe()
  end

  # --- bounded per-page link preload (AC-27.16.3/.5, #7 truncation marker) ---

  # Load BOTH directions of links for the page's articles in ONE tenant-scoped
  # query, capped to `max_links_per_article/0` PER (article, direction) via a window
  # function so a dense hub's fan-out is bounded in SQL — never fetched, never
  # materialized into one entry. To make truncation DETECTABLE (#7), fetch `cap + 1`
  # rows per (article, direction): if `cap + 1` came back, the list was truncated —
  # the extra row is dropped and the article is flagged. Returns
  # `%{article_id => {links_trimmed_to_cap, truncated?}}`.
  defp load_bounded_links(tenant_id, page) do
    ids = Enum.map(page, & &1.id)
    cap = max_links_per_article()

    outgoing = fetch_links(tenant_id, ids, :outgoing, cap)
    incoming = fetch_links(tenant_id, ids, :incoming, cap)

    (outgoing ++ incoming)
    |> Enum.group_by(& &1.owner_id)
    |> Map.new(fn {owner_id, links} -> {owner_id, trim_and_flag(links, cap)} end)
  end

  # Per article: across BOTH directions, trim each direction back to `cap` and flag
  # truncation if EITHER direction returned more than `cap` (we fetched cap+1).
  defp trim_and_flag(links, cap) do
    {kept, truncated?} =
      links
      |> Enum.group_by(& &1.direction)
      |> Enum.reduce({[], false}, fn {_dir, dir_links}, {acc, trunc?} ->
        over? = length(dir_links) > cap
        kept_dir = dir_links |> Enum.take(cap) |> Enum.map(&Map.delete(&1, :owner_id))
        {acc ++ kept_dir, trunc? or over?}
      end)

    {kept, truncated?}
  end

  # Per-direction, ranked-and-capped link rows joined to the neighbor article (for
  # its title/status), tenant-scoped on BOTH the link table AND the neighbor join
  # (BYPASSRLS — every source must carry the tenant predicate).
  defp fetch_links(_tenant_id, [], _direction, _cap), do: []

  defp fetch_links(tenant_id, ids, :outgoing, cap) do
    ranked =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id and l.source_article_id in ^ids,
        select: %{
          owner_id: l.source_article_id,
          neighbor_id: l.target_article_id,
          relationship_type: l.relationship_type,
          rn:
            over(row_number(),
              partition_by: l.source_article_id,
              order_by: [asc: l.relationship_type, asc: l.target_article_id]
            )
        }
      )

    capped_links(tenant_id, ranked, cap, :outgoing)
  end

  defp fetch_links(tenant_id, ids, :incoming, cap) do
    ranked =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id and l.target_article_id in ^ids,
        select: %{
          owner_id: l.target_article_id,
          neighbor_id: l.source_article_id,
          relationship_type: l.relationship_type,
          rn:
            over(row_number(),
              partition_by: l.target_article_id,
              order_by: [asc: l.relationship_type, asc: l.source_article_id]
            )
        }
      )

    capped_links(tenant_id, ranked, cap, :incoming)
  end

  # Fetch cap+1 (the "peek") so the caller can DETECT truncation (#7): if cap+1 rows
  # came back for a direction, the real fan-out exceeded the cap. `trim_and_flag/2`
  # drops the extra and flags the article. Peak fetch is still bounded (cap+1 per
  # direction × page_size articles).
  defp capped_links(tenant_id, ranked, cap, direction) do
    peek = cap + 1

    query =
      from(r in subquery(ranked),
        join: a in Article,
        on: a.id == r.neighbor_id and a.tenant_id == ^tenant_id,
        where: r.rn <= ^peek,
        select: %{
          owner_id: r.owner_id,
          neighbor_id: r.neighbor_id,
          relationship_type: r.relationship_type,
          title: a.title,
          category: a.category,
          status: a.status
        }
      )

    # Export link queries use the same extended 60s timeout + heavy `:export` weight as
    # export pages. A shed (OverloadedError) is caught by `emit_article_page/5`'s rescue
    # (this runs inside its per-page link preload) → fail-closed abort.
    tenant_id
    |> HeavyRead.all(query, export_read_opts())
    |> Enum.map(&Map.put(&1, :direction, direction))
  end

  # --- shared query + helpers ---

  # Heavy-read opts shared by every export scan (page / aggregate / link preload): the
  # extended 60s `SET LOCAL statement_timeout` AND the `:export` telemetry endpoint that
  # weights the read HEAVY on `Loopctl.HeavyRead.TenantGate` (US-37.5). The default
  # `on_overload: :raise` disposition is deliberate — the raise fails closed via the
  # caller's rescue (see the moduledoc "overload disposition" section).
  defp export_read_opts do
    [
      statement_timeout: @export_statement_timeout_ms,
      telemetry_options: [endpoint: @export_endpoint]
    ]
  end

  @doc """
  The export base query: the EXACT WHERE of the legacy `export_base_query/2`
  (tenant_id + status=:published + the `project_id IS NULL OR project_id == ^pid`
  disjunction). Exposed so the id-set-equality test (TC-27.16.4) can assert the
  streamed walk and the legacy fetch select the same rows.
  """
  @spec base_query(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  def base_query(tenant_id, project_id) do
    query = from(a in Article, where: a.tenant_id == ^tenant_id and a.status == :published)

    cond do
      is_nil(project_id) ->
        query

      # Defense in depth: `project_id` is a `:binary_id` column, so a non-UUID
      # value would raise Ecto.Query.CastError on the `== ^project_id` comparison
      # — and here it would do so AFTER `send_chunked` already committed a 200,
      # truncating the archive. The controller 422s before streaming; a malformed
      # value that still reaches here scopes to tenant-wide articles only.
      valid_uuid?(project_id) ->
        where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)

      true ->
        where(query, [a], is_nil(a.project_id))
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  # The `(inserted_at, id)` keyset seek, shared with the article/index/change-feed
  # keysets via Loopctl.KeysetSeek (the load-bearing type/2 annotations live there).
  defp apply_keyset_seek(query, cursor), do: KeysetSeek.after_position(query, cursor)

  defp emit_entries(writer, entries) do
    Enum.reduce_while(entries, {:ok, writer}, fn {path, content}, {:ok, writer} ->
      case TarGz.add_entry(writer, path, content) do
        {:ok, writer} -> {:cont, {:ok, writer}}
        {:error, reason} -> {:halt, {:error, reason, writer}}
      end
    end)
  end

  # Rebuild a minimal %Article{} from the projection so format impls can pattern
  # match on the struct (they read only these fields).
  defp to_article(row) do
    %Article{
      id: row.id,
      tenant_id: row.tenant_id,
      project_id: row.project_id,
      title: row.title,
      body: row.body,
      category: row.category,
      status: row.status,
      tags: row.tags || [],
      source_type: Map.get(row, :source_type),
      metadata: Map.get(row, :metadata) || %{},
      inserted_at: row.inserted_at,
      updated_at: row.updated_at,
      suppressed_at: Map.get(row, :suppressed_at),
      suppressed_by: Map.get(row, :suppressed_by),
      suppression_reason: Map.get(row, :suppression_reason)
    }
  end
end
