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

  Read section (a)'s `at dim=... AND live_denorm AND published` COUNT first — it is an
  unlimited `count()` carrying the read's own visibility predicates, unlike the row sample
  under it. Non-zero means hypothesis (a) is dead and the plan in section (b) is where the row
  was lost. Zero means the read never had a candidate and no amount of ANN tuning is relevant.
  Never make that call from the SAMPLE: it is capped, so an absent row there is not an absent
  row — the sample is for seeing WHICH predicate a row failed, once the counts disagree.

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
      would apply" line is what an ANN read issued with `HeavyRead.opts/1` uses — a bare
      `HeavyRead.all/2` (the `:query` branch) uses none of it and is EXPLAINed accordingly.
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
  # wall of text. It is a SAMPLE and routinely full — the ~two dozen materialized system
  # rows alone reach it — so the counts printed beside it come from unlimited `count()`
  # queries, never from `length(rows)`. (They once came from the sample, which made a
  # tenant row that sorted past the cap read as "never visible" — the wrong branch of the
  # (a)-vs-(b) split this module exists to decide.) The sample is ordered with the read's
  # own `dim` FIRST for the same reason.
  @sample_limit 25

  # The diagnostic runs after a read already returned, so re-executing the same read-only
  # query is safe — and `ANALYZE` is what makes the plan decisive: it reports rows ACTUALLY
  # produced per node, which is exactly the (a)-vs-(b) split. A plain `EXPLAIN` is the
  # fallback when `ANALYZE` will not run.
  @explain_timeout_ms 15_000

  # The GUCs `HeavyRead` sets per ANN read, re-applied around the EXPLAIN so the plan
  # describes the read's execution rather than the session default's. `hnsw.max_scan_tuples`
  # is here because `HeavyRead` sets it in the SAME breath as `hnsw.iterative_scan` — it is
  # the ceiling that bounds the iterative walk, and leaving it at the session value would
  # let the EXPLAIN walk further than the read could.
  @read_gucs ["hnsw.ef_search", "hnsw.iterative_scan", "hnsw.max_scan_tuples"]

  # The planner GUCs `HeavyRead` sets on EVERY heavy read when
  # `:heavy_read_force_exact_scan` is on (the default suite — see
  # `Loopctl.HeavyRead.maybe_force_exact_scan/1`). They are tracked separately from
  # `@read_gucs` because they are not ANN opts: `@read_gucs` is armed only for a read that
  # asked for an ef_search, while these apply to a bare `HeavyRead.all/2` as well, which is
  # exactly the `:session_defaults` case below.
  @exact_scan_gucs ["enable_indexscan", "enable_bitmapscan"]

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
    {total, at_dim, visible} = tenant_counts(tenant_id, dim)

    rows =
      AdminRepo.all(
        from(ae in ArticleEmbedding,
          left_join: a in Article,
          on: a.id == ae.article_id,
          where: ae.tenant_id == ^tenant_id,
          order_by: [desc: fragment("? = ?", ae.dim, ^dim), asc: ae.dim, asc: ae.article_id],
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
      "  tenant rows: #{total} (COUNT — authoritative)",
      "  at dim=#{dim}: #{at_dim} (COUNT — authoritative)",
      "  at dim=#{dim} AND live_denorm AND published: #{visible} " <>
        "(COUNT — authoritative; ZERO here is hypothesis (a))",
      "  corpus-wide rows at dim=#{dim} (ALL tenants — how crowded the shared index is): " <>
        "#{global_count(dim)}",
      "  sample below: #{length(rows)} of them, dim=#{dim} first, capped at #{@sample_limit}"
    ]
    |> Enum.map(&[&1, "\n"])
    |> Kernel.++(Enum.map(rows, &["    ", format_row(&1), "\n"]))
  end

  # Unlimited counts, so the (a)-vs-(b) call is never made on a truncated sample. The third
  # one carries the read's OWN visibility predicates (`dim` + `live_denorm` + a published
  # article): counting only `(tenant_id, dim)` still left the live/status half of hypothesis
  # (a) readable nowhere but the capped sample, which is the truncation this exists to remove.
  defp tenant_counts(tenant_id, dim) do
    AdminRepo.one(
      from(ae in ArticleEmbedding,
        left_join: a in Article,
        on: a.id == ae.article_id,
        where: ae.tenant_id == ^tenant_id,
        select: {
          count(),
          filter(count(), ae.dim == ^dim),
          filter(count(), ae.dim == ^dim and ae.live_denorm and a.status == :published)
        }
      )
    )
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
      "  (caller-supplied query — EXPLAINed at SESSION defaults, no hnsw.* SET LOCAL, " <>
        "because a bare HeavyRead.all/2 sets none either)\n"
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
  # `:session_defaults` is NOT "no opinion" — it is the faithful reproduction of a read that
  # set no GUC at all. A caller-supplied `:query` comes from an assertion on a bare
  # `HeavyRead.all/2`, which carries no `hnsw_*` opts and therefore emits no `SET LOCAL`;
  # arming ef_search/iterative_scan here would print a healthy plan for a read that ran
  # without them, and iterative-scan-on-vs-off is exactly the difference between an ANN that
  # under-returns past its first batch and one that does not.
  # `:session_defaults` reproduces a read that set no ANN GUC — but "no ANN GUC" was never
  # "no GUC at all". When exact-scan forcing is on, `HeavyRead` applies it to EVERY heavy
  # read including a bare `HeavyRead.all/2`, so this branch must arm it too or it prints an
  # INDEX plan for a read that could not have used the index.
  defp with_read_gucs(:session_defaults, fun) do
    {:ok, result} =
      AdminRepo.transaction(fn ->
        LocalGuc.scoped(AdminRepo, exact_scan_gucs(), fn ->
          set_exact_scan()
          fun.()
        end)
      end)

    result
  end

  defp with_read_gucs(ef_search, fun) do
    {:ok, result} =
      AdminRepo.transaction(fn ->
        LocalGuc.scoped(AdminRepo, @read_gucs ++ exact_scan_gucs(), fn ->
          set_iterative_scan()
          set_exact_scan()
          AdminRepo.query!("SET LOCAL hnsw.ef_search = #{ef_search}", [])
          fun.()
        end)
      end)

    result
  end

  # Deliberately reads the SAME source of truth `HeavyRead` reads
  # (`HeavyRead.force_exact_scan?/0` -> `:heavy_read_force_exact_scan`). This is the
  # opposite of the rule the chokepoint GUARD in
  # `test/loopctl/embeddings/hnsw_dead_entry_recall_test.exs` follows, and the difference is
  # the point: a guard needs an INDEPENDENT source or it moves with the thing it guards and
  # goes vacuous, while a diagnostic needs the SAME source or it stops describing the read
  # it is explaining. Do not "fix" this one to derive from `SCALE_TESTS`.
  defp exact_scan_gucs do
    if HeavyRead.force_exact_scan?(), do: @exact_scan_gucs, else: []
  end

  defp set_exact_scan do
    if HeavyRead.force_exact_scan?() do
      Enum.each(@exact_scan_gucs, &AdminRepo.query!("SET LOCAL #{&1} = off", []))
    end

    :ok
  end

  defp set_iterative_scan do
    case HeavyRead.hnsw_iterative_scan() do
      "off" ->
        :ok

      mode ->
        if HeavyRead.iterative_scan_supported?() do
          AdminRepo.query!("SET LOCAL hnsw.iterative_scan = #{mode}", [])

          AdminRepo.query!(
            "SET LOCAL hnsw.max_scan_tuples = #{HeavyRead.hnsw_max_scan_tuples()}",
            []
          )
        end
    end

    :ok
  end

  defp explain_query(tenant_id, opts) do
    case Keyword.get(opts, :query) do
      nil -> rebuilt_pool_query(tenant_id, opts)
      query -> {query, :session_defaults}
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
