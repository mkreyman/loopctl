defmodule Loopctl.VectorRecallDiagnostics do
  @moduledoc """
  On-failure diagnostics for the `left: []` signature in the side-table vector-recall
  tests (`test/loopctl/embeddings_side_table_reads_test.exs` and its siblings).

  That failure has survived four fixes because a bare `left: []` cannot distinguish the
  only two hypotheses that matter:

    * **(a) NOT VISIBLE** — the row the assertion wants was never a candidate for this
      read: wrong tenant, wrong `dim`, `live_denorm` false, non-`published` status, an
      article row the hydration filters would drop.
    * **(b) VISIBLE BUT NOT RETURNED** — the row was a legitimate candidate and the PLAN
      did not hand it back: an approximate index scan, a post-index residual filter, a
      `LIMIT` the candidate set overflowed.

  `diagnose_empty/2` dumps BOTH facts, and only when the observed result list is EMPTY.
  Nothing here runs on the success path, and nothing here changes what a test asserts —
  it prints, then the ordinary assertion fails with its ordinary message.

  ## It must never become the failure

  Every section is independently wrapped: an exception or an exit inside a diagnostic is
  caught and printed as a one-line reason, so a diagnostic that cannot run degrades to
  saying so rather than replacing the real assertion failure with its own stacktrace.

  ## Reading the output

  If section (a) lists rows for the tenant at the read's dimension with
  `live_denorm=true` and a `published` status, hypothesis (a) is dead and the plan in
  section (b) is where the row was lost. If section (a) is empty or the rows carry a
  different `dim`/status, the read never had a candidate and no amount of ANN tuning is
  relevant.

  Two caveats that are part of the reading, not footnotes:

    * **This runs AFTER the read.** `search_semantic/3` triggers on-demand
      materialization of the ~two dozen COMMITTED system-scoped articles for the calling
      tenant as a side effect of building its disclosure `meta`, so the corpus section (a)
      reports — and the corpus `ANALYZE` re-executes against — can be strictly larger than
      the one the failing read actually scanned. A large section (a) is therefore not by
      itself proof that the read had those candidates.
    * **The GUCs are read on a different connection.** `HeavyRead` applies `hnsw.ef_search`
      / `hnsw.iterative_scan` with `SET LOCAL` inside its own transaction, which this
      diagnostic cannot see. The "session" line is the value OUTSIDE that transaction (a
      non-default there means a `SET LOCAL` leaked — the #535 mechanism); the "HeavyRead
      would apply" line is what the read itself used.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.LocalGuc

  # Enough rows to characterise a test tenant's corpus without turning a failure into a
  # wall of text. These tests seed single digits of rows; a sample this size that is
  # FULL is itself the signal that something seeded far more than expected.
  @sample_limit 25

  # The diagnostic runs after a read already returned, so re-executing the same read-only
  # query is safe — and `ANALYZE` is what makes the plan decisive: it reports rows ACTUALLY
  # produced per node, which is exactly the (a)-vs-(b) split. A plain `EXPLAIN` is the
  # fallback when `ANALYZE` will not run.
  @explain_timeout_ms 15_000

  # The GUCs `HeavyRead` sets per ANN read, re-applied around the EXPLAIN so the plan
  # describes the read's execution rather than the session default's.
  @read_gucs ["hnsw.ef_search", "hnsw.iterative_scan"]

  @doc """
  Prints the (a)-visibility / (b)-plan diagnostic when `observed` is empty, and returns
  `observed` unchanged so it can be used inline or as a bare statement before the assertion.

  `observed` is whatever the assertion is about to look at — the result list, or the list
  of ids taken from it.

  Options:

    * `:tenant_id` (required) — the tenant the read was scoped to.
    * `:dim` (required) — the dimension the read scanned.
    * `:query_vector` — the query embedding, used to rebuild the REAL request-path pool
      query for the plan. Omit it only when passing `:query`.
    * `:query` — an explicit `Ecto.Query` to EXPLAIN instead of the rebuilt pool query
      (for assertions that ran their own query, e.g. a direct `HeavyRead.all/2`).
    * `:limit` — the `:limit` the read was issued with (default `10`, matching
      `search_semantic/3`), so the rebuilt pool size matches the real one.
    * `:offset` — likewise (default `0`).
    * `:label` — a short string naming the assertion, printed in the header.
  """
  @spec diagnose_empty(list(), keyword()) :: list()
  def diagnose_empty([], opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    dim = Keyword.fetch!(opts, :dim)

    IO.puts([
      "\n=== EMPTY VECTOR RECALL — DIAGNOSTIC",
      label_suffix(Keyword.get(opts, :label)),
      " ===\n",
      "tenant_id=#{tenant_id} dim=#{dim}\n",
      section("(0) BACKEND", fn -> backend_settings() end),
      section("(a) VISIBILITY — candidate rows for this tenant (AdminRepo, no ANN)", fn ->
        visibility(tenant_id, dim)
      end),
      section("(b) PLAN — the query that just returned empty", fn -> plan(tenant_id, opts) end),
      "=== END DIAGNOSTIC ===\n"
    ])

    []
  end

  def diagnose_empty(observed, _opts), do: observed

  defp label_suffix(nil), do: ""
  defp label_suffix(label), do: [" (", to_string(label), ")"]

  # Each section is independently guarded. `catch` covers the EXIT a DBConnection
  # ownership/timeout failure raises as, which is precisely the DB state most likely to
  # be in play when a read came back empty — the one case where an unguarded diagnostic
  # would replace the real failure with its own.
  defp section(title, fun) do
    body =
      try do
        fun.()
      rescue
        e -> "  <diagnostic unavailable: #{Exception.message(e)}>\n"
      catch
        kind, reason -> "  <diagnostic unavailable: #{kind} #{inspect(reason)}>\n"
      end

    ["--- ", title, " ---\n", body]
  end

  # pgvector version and the ANN GUCs in force. A `SET LOCAL` that leaked from an earlier
  # read (the #535 mechanism) shows up here, and so does an iterative_scan setting that is
  # not what the config says it should be.
  defp backend_settings do
    %{rows: [[version, ef_search, iterative_scan, statement_timeout]]} =
      AdminRepo.query!(
        """
        SELECT (SELECT extversion FROM pg_extension WHERE extname = 'vector'),
               current_setting('hnsw.ef_search', true),
               current_setting('hnsw.iterative_scan', true),
               current_setting('statement_timeout', true)
        """,
        []
      )

    "  pgvector=#{inspect(version)}\n" <>
      "  session (OUTSIDE the read's SET LOCAL — a non-default here means one LEAKED): " <>
      "hnsw.ef_search=#{inspect(ef_search)} hnsw.iterative_scan=#{inspect(iterative_scan)} " <>
      "statement_timeout=#{inspect(statement_timeout)}\n" <>
      "  HeavyRead would apply: hnsw.iterative_scan=#{inspect(HeavyRead.hnsw_iterative_scan())} " <>
      "(supported?=#{inspect(HeavyRead.iterative_scan_supported?())}) " <>
      "hnsw.ef_search=#{inspect(HeavyRead.hnsw_ef_search())}\n"
  end

  # (a) — what the read COULD have returned, read the least filtered way available:
  # AdminRepo (BYPASSRLS), no vector predicate, no dimension predicate, no join
  # condition that can drop a row. Anything absent here was never visible.
  defp visibility(tenant_id, dim) do
    rows =
      AdminRepo.all(
        from(ae in ArticleEmbedding,
          left_join: a in Article,
          on: a.id == ae.article_id,
          where: ae.tenant_id == ^tenant_id,
          order_by: [asc: ae.dim, asc: ae.article_id],
          limit: @sample_limit,
          select: %{
            article_id: ae.article_id,
            dim: ae.dim,
            live_denorm: ae.live_denorm,
            status: a.status,
            scope: a.scope,
            article_tenant_id: a.tenant_id
          }
        )
      )

    [
      "  tenant rows: #{length(rows)} (sample capped at #{@sample_limit})",
      "  at dim=#{dim}: #{Enum.count(rows, &(&1.dim == dim))}",
      "  corpus-wide rows at dim=#{dim} (ALL tenants — how crowded the shared index is): " <>
        "#{global_count(dim)}"
    ]
    |> Enum.map(&[&1, "\n"])
    |> Kernel.++(Enum.map(rows, &["    ", format_row(&1), "\n"]))
  end

  defp format_row(row) do
    "article_id=#{row.article_id} dim=#{row.dim} live_denorm=#{inspect(row.live_denorm)} " <>
      "article.status=#{inspect(row.status)} article.scope=#{inspect(row.scope)} " <>
      "article.tenant_id=#{inspect(row.article_tenant_id)}"
  end

  defp global_count(dim) do
    AdminRepo.one(from(ae in ArticleEmbedding, where: ae.dim == ^dim, select: count()))
  end

  # (b) — the plan for the EXACT request-path query. Rebuilt from the same public
  # `Knowledge.semantic_side_table_pool_query/4` + `semantic_result_pool/1` the read used,
  # never a hand-written lookalike, so the plan describes what actually ran.
  defp plan(tenant_id, opts) do
    {query, ef_search} = explain_query(tenant_id, opts)

    explained =
      case explain(query, ef_search, "EXPLAIN (ANALYZE, BUFFERS) ") do
        {:ok, plan} -> plan
        {:error, analyze_reason} -> explain_without_analyze(analyze_reason, query, ef_search)
      end

    [pool_note(opts), "  ", explained |> elide_vectors() |> String.replace("\n", "\n  "), "\n"]
  end

  # A 1536-dimension vector literal renders as ~4 KB on ONE line, which pushes the
  # `Rows Removed by Filter` / `actual rows` counters — the numbers the whole diagnostic
  # exists to show — off the readable part of the output.
  defp elide_vectors(plan) do
    String.replace(plan, ~r/'\[[0-9eE.,+-]{120,}\]'/, "'[<vector literal elided>]'")
  end

  # The pool sizes are the whole reason a plan can be exact and still under-return, so
  # state them next to the plan rather than leaving the reader to recompute them.
  defp pool_note(opts) do
    if Keyword.has_key?(opts, :query) do
      "  (caller-supplied query)\n"
    else
      limit = Keyword.get(opts, :limit, 10)
      offset = Keyword.get(opts, :offset, 0)
      pool = Knowledge.semantic_result_pool(offset + limit)

      "  limit=#{limit} offset=#{offset} -> pool=#{pool} " <>
        "inner_pool=#{VectorSearch.side_table_inner_pool(pool)} " <>
        "(pool is min(max(offset+limit, floor), cap) — a limit above the CAP buys nothing)\n"
    end
  end

  defp explain_without_analyze(analyze_reason, query, ef_search) do
    case explain(query, ef_search, "EXPLAIN ") do
      {:ok, plan} -> "<ANALYZE unavailable: #{analyze_reason}; plain EXPLAIN follows>\n" <> plan
      {:error, reason} -> "<EXPLAIN unavailable: #{reason}>"
    end
  end

  # Raw SQL rather than `Repo.explain/3`: with `analyze: true` Ecto runs the EXPLAIN in a
  # transaction it deliberately ROLLS BACK, which aborts the enclosing `with_read_gucs/2`
  # transaction (and takes the connection with it). Rendering the SQL ourselves keeps the
  # EXPLAIN inside the GUC scope, where it belongs.
  defp explain(query, ef_search, prefix) do
    {sql, params} = SQL.to_sql(:all, AdminRepo, query)

    rows =
      with_read_gucs(ef_search, fn ->
        AdminRepo.query!(prefix <> sql, params, timeout: @explain_timeout_ms).rows
      end)

    {:ok, rows |> Enum.map_join("\n", &Enum.join(&1, " ")) |> String.trim()}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind} #{inspect(reason)}"}
  end

  # The read applies its `hnsw.*` GUCs with `SET LOCAL` inside its OWN transaction, so an
  # EXPLAIN at session defaults can describe a different execution than the one that just
  # came back empty — and on this path the difference is the whole question (iterative scan
  # is what keeps the post-index `tenant_id` residual filter from under-returning).
  #
  # Routed through `Loopctl.LocalGuc` because a `SET LOCAL` leaks out of a committed
  # SAVEPOINT under the Sandbox (#535): without its capture/restore, a diagnostic would arm
  # these GUCs over the REST of the test it was added to explain.
  defp with_read_gucs(ef_search, fun) do
    {:ok, result} =
      AdminRepo.transaction(fn ->
        LocalGuc.scoped(AdminRepo, @read_gucs, fn ->
          set_iterative_scan()
          AdminRepo.query!("SET LOCAL hnsw.ef_search = #{ef_search}", [])
          fun.()
        end)
      end)

    result
  end

  defp set_iterative_scan do
    case HeavyRead.hnsw_iterative_scan() do
      "off" ->
        :ok

      mode ->
        if HeavyRead.iterative_scan_supported?() do
          AdminRepo.query!("SET LOCAL hnsw.iterative_scan = #{mode}", [])
        end
    end

    :ok
  end

  defp explain_query(tenant_id, opts) do
    case Keyword.get(opts, :query) do
      nil -> rebuilt_pool_query(tenant_id, opts)
      query -> {query, HeavyRead.hnsw_ef_search()}
    end
  end

  defp rebuilt_pool_query(tenant_id, opts) do
    dim = Keyword.fetch!(opts, :dim)
    vector = Keyword.fetch!(opts, :query_vector)
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)

    inner_pool =
      (offset + limit)
      |> Knowledge.semantic_result_pool()
      |> VectorSearch.side_table_inner_pool()

    {Knowledge.semantic_side_table_pool_query(tenant_id, vector, dim, inner_pool),
     VectorSearch.side_table_ef_search(inner_pool)}
  end
end
