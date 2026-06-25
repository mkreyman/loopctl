defmodule Loopctl.PlanAssertions do
  @moduledoc """
  Query-plan assertions for scale tests (US-27.2).

  The point of this module is to catch the exact false-green that shipped the
  `suggested_links` 500 three times: a query whose ORDER BY is index-*eligible* but
  which the planner does NOT actually use at prod scale (it reads the whole corpus +
  Sorts, then times out).

  CRITICAL: these assertions run `EXPLAIN` WITHOUT forcing the planner
  (`enable_seqscan`/`enable_sort` are left at their defaults). Forcing the planner
  proves index *eligibility*, not that the planner *chooses* the index — that
  distinction is precisely what produced false confidence in #172. So these are
  meaningful ONLY against a committed, ANALYZEd, ≥prod-scale corpus
  (`Loopctl.Knowledge.ScaleSeed`); at toy scale the planner Seq-Scans happily and the
  assertion would be a lie. `assert_fresh_stats!/0` enforces that precondition.

  We parse `EXPLAIN (FORMAT JSON)` and walk the node tree rather than regex the text
  form, so the assertions key on the *property* "how is `articles` reached" — not on a
  single spelling of a bad node. A regression that reaches the full corpus via
  `Seq Scan`, `Parallel Seq Scan`, OR `Bitmap Heap Scan` (all the #172 shapes) is
  caught; and `assert_hnsw_index` requires `articles` to be reached by EXACTLY ONE
  scan, an Index Scan on an `amname='hnsw'` index (no sibling full-scan can hide).
  """

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo

  # Node types that read the whole `articles` relation (the #172 timeout shape).
  # "Seq Scan" covers Parallel Seq Scan (same Node Type, Parallel Aware flag).
  @full_scan_types ["Seq Scan", "Bitmap Heap Scan"]

  @doc """
  Asserts the planner does NOT reach `articles` via a full-corpus scan (`Seq Scan`,
  `Parallel Seq Scan`, or `Bitmap Heap Scan`) for the given query. Accepts an Ecto
  queryable or a `{sql, params}` tuple (the latter lets a caller assert on the request
  path's captured SQL+params — AC-27.2.4). Raises with the offending plan (vectors
  elided) on a full scan. Runs the planner's natural choice — no `enable_seqscan=off`.
  """
  def refute_full_scan(queryable_or_sql) do
    assert_fresh_stats!()
    {root, raw} = explain_json(queryable_or_sql)
    scans = article_scan_nodes(root)

    bad = Enum.filter(scans, &(&1.node_type in @full_scan_types))

    refute_full_scan_result(scans, bad, raw)
  end

  @doc """
  Like `refute_full_scan/1` but targets the `audit_log` relation (US-27.9b change
  feed). `audit_log` is RANGE-partitioned, so EXPLAIN reaches it via CHILD partition
  relations (e.g. `audit_log_y2026m06`); this matches any relation whose name starts
  with `audit_log` (parent or partition). Guards on an audit-flavored fresh-stats check
  (`assert_fresh_stats_audit!/0`) instead of the `articles`-specific `assert_fresh_stats!/0`,
  so a future seed that drops the ANALYZE can't silently false-green.
  """
  def refute_full_scan_audit(queryable_or_sql) do
    assert_fresh_stats_audit!()
    {root, raw} = explain_json(queryable_or_sql)
    scans = relation_scan_nodes(root, "audit_log")
    bad = Enum.filter(scans, &(&1.node_type in @full_scan_types))

    refute_full_scan_result(scans, bad, raw)
  end

  @doc """
  Audit-flavored sibling of `assert_fresh_stats!/0` (US-27.9b): raises unless
  `audit_log` holds real rows AND at least one `audit_log*` partition has been ANALYZEd
  (non-null `last_analyze`/`last_autoanalyze` in `pg_stat_user_tables`). Prevents a
  change-feed plan assertion from running against an unseeded/unanalyzed corpus — a seed
  that drops the `ANALYZE audit_log` would otherwise false-green (toy stats → the
  planner picks a Seq Scan but the assertion can't tell, or the EXPLAIN row estimates
  are meaningless).
  """
  def assert_fresh_stats_audit! do
    %{rows: [[real_count]]} = AdminRepo.query!("SELECT count(*) FROM audit_log")

    # Any audit_log partition with a non-null analyze timestamp counts as "analyzed".
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT count(*) FILTER (WHERE last_analyze IS NOT NULL OR last_autoanalyze IS NOT NULL)
      FROM pg_stat_user_tables
      WHERE relname LIKE 'audit_log_y%'
      """)

    analyzed_partitions =
      case rows do
        [[n]] when is_integer(n) -> n
        _ -> 0
      end

    cond do
      is_nil(real_count) or real_count <= 0 ->
        raise ExUnit.AssertionError,
          message:
            "Change-feed plan assertion ran against an EMPTY `audit_log` (count=#{inspect(real_count)}). " <>
              "Seed via Loopctl.Knowledge.ScaleSeed.seed_changes/2 (unboxed, committed) first."

      analyzed_partitions == 0 ->
        raise ExUnit.AssertionError,
          message:
            "Change-feed plan assertion ran against an UNANALYZED `audit_log` (no partition has " <>
              "last_analyze/last_autoanalyze). ScaleSeed.seed_changes/2 runs `ANALYZE audit_log`; " <>
              "ensure it isn't dropped before asserting."

      true ->
        :ok
    end
  end

  defp refute_full_scan_result(scans, bad, raw) do
    cond do
      scans == [] ->
        raise ExUnit.AssertionError,
          message:
            "Plan never reaches the target relation — cannot judge full-scan vs index. Plan:\n#{elide(raw)}"

      bad != [] ->
        raise ExUnit.AssertionError,
          message:
            "Expected the target relation reached via an index, but a full-corpus scan node is " <>
              "present: #{inspect(Enum.map(bad, & &1.node_type))} (the #170/#172 prod-500 " <>
              "shape). Plan:\n#{elide(raw)}"

      true ->
        :ok
    end
  end

  @doc """
  Like `refute_seq_scan/1` but targets the `audit_log` relation (US-27.9b change
  feed). Allows a Bitmap Heap Scan driven by a selective index but forbids an
  unbounded Seq Scan over the (partitioned) `audit_log`. Matches any relation whose
  name starts with `audit_log` (parent or partition). Guards on the audit-flavored
  `assert_fresh_stats_audit!/0` (not the `articles`-specific `assert_fresh_stats!/0`).
  """
  def refute_seq_scan_audit(queryable_or_sql) do
    assert_fresh_stats_audit!()
    {root, raw} = explain_json(queryable_or_sql)
    scans = relation_scan_nodes(root, "audit_log")
    bad = Enum.filter(scans, &(&1.node_type == "Seq Scan"))

    cond do
      scans == [] ->
        raise ExUnit.AssertionError,
          message:
            "Plan never reaches the `audit_log` relation — cannot judge scan shape. Plan:\n#{elide(raw)}"

      bad != [] ->
        raise ExUnit.AssertionError,
          message:
            "Expected no Seq Scan on `audit_log` (unbounded full read), but one is present. " <>
              "Plan:\n#{elide(raw)}"

      true ->
        :ok
    end
  end

  @doc """
  Asserts the `audit_log` plan reaches **at least `min_partitions` distinct partition
  relations** (`audit_log_yYYYYmMM`) via per-partition INDEX SCANS combined under an
  ordered multi-partition node (US-27.9b). This is the prod shape for a deep
  change-feed page whose cursor range spans months.

  Postgres has TWO valid plans for `ORDER BY inserted_at, id` across partitions whose
  index is `(tenant_id, inserted_at)` (no `id`):

  - a **Merge Append** of per-partition Index Scans (when an index fully provides the
    sort key), OR
  - an **Append** of per-partition Index Scans + a top-level **Incremental Sort** /
    **Sort** (presorted on `inserted_at`, finishing the `id` tie-break).

  Both are correct, ordered, and bounded (no Seq/Bitmap over the corpus); the planner
  picks by cost. We accept EITHER, and require that ≥`min_partitions` partitions are
  reached by Index Scans (so the seed genuinely straddled the boundary and the plan is
  not a single-partition shortcut that would make `refute_full_scan_audit` vacuous).
  Pair with `refute_full_scan_audit/1` (forbids Seq/Bitmap on every partition).
  """
  def assert_ordered_multi_partition_scan(queryable_or_sql, min_partitions)
      when is_integer(min_partitions) do
    {root, raw} = explain_json(queryable_or_sql)

    # Per-partition Index Scans (the bounded ordered access on each partition).
    index_partitions =
      root
      |> relation_scan_nodes("audit_log_y")
      |> Enum.filter(&(&1.node_type in ["Index Scan", "Index Only Scan"]))
      |> Enum.map(& &1.relation)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # A multi-partition combiner: Merge Append (index-merged), OR Append paired with a
    # top-level Sort/Incremental Sort that finishes the global order.
    ordered_combiner? =
      node_type_present?(root, "Merge Append") or
        (node_type_present?(root, "Append") and
           (node_type_present?(root, "Incremental Sort") or node_type_present?(root, "Sort")))

    cond do
      length(index_partitions) < min_partitions ->
        raise ExUnit.AssertionError,
          message:
            "Expected ≥ #{min_partitions} distinct audit_log partitions reached by Index Scan " <>
              "(a real boundary-straddling page), got #{length(index_partitions)}: " <>
              "#{inspect(index_partitions)}. The seed must span ≥2 monthly partitions. " <>
              "Plan:\n#{elide(raw)}"

      not ordered_combiner? ->
        raise ExUnit.AssertionError,
          message:
            "Expected an ordered multi-partition combiner (Merge Append, or Append + " <>
              "Incremental Sort/Sort) over the audit_log partitions, but none is present. " <>
              "Plan:\n#{elide(raw)}"

      true ->
        :ok
    end
  end

  # True if any node anywhere in the plan tree has the given Node Type.
  defp node_type_present?(node, type) when is_map(node) do
    here = node["Node Type"] == type

    here or
      node
      |> Map.get("Plans", [])
      |> Enum.any?(&node_type_present?(&1, type))
  end

  @doc """
  Weaker than `refute_full_scan/1`: asserts `articles` is not read by a `Seq Scan`
  or `Parallel Seq Scan` (the genuinely UNBOUNDED full-corpus shapes), while ALLOWING
  a `Bitmap Heap Scan` driven by a selective index.

  This is for query shapes that legitimately cannot be served by a single ordered
  index — specifically a keyset walk combined with an ARRAY-membership residual
  (`tags &&`, served by a GIN index). No btree can provide both array containment AND
  the `(inserted_at, id)` order, so the planner intersects the GIN bitmap with the
  keyset btree (a `BitmapAnd`) and Sorts the (selective) result. That is bounded by
  the residual's selectivity — NOT the corpus — and is the same plan a tag-filtered
  OFFSET query already used; it is therefore non-regressive, just not true-keyset-cheap.
  Pair this with `assert_index_used/2` for the selective driver to prove the bound.
  """
  def refute_seq_scan(queryable_or_sql) do
    assert_fresh_stats!()
    {root, raw} = explain_json(queryable_or_sql)
    scans = article_scan_nodes(root)
    bad = Enum.filter(scans, &(&1.node_type == "Seq Scan"))

    cond do
      scans == [] ->
        raise ExUnit.AssertionError,
          message:
            "Plan never reaches the `articles` relation — cannot judge scan shape. Plan:\n#{elide(raw)}"

      bad != [] ->
        raise ExUnit.AssertionError,
          message:
            "Expected no Seq Scan on `articles` (unbounded full-corpus read), but one is present. " <>
              "Plan:\n#{elide(raw)}"

      true ->
        :ok
    end
  end

  @doc """
  Asserts every scan node on `articles` has an estimated row count below `max_rows`.

  Companion to `refute_seq_scan/1` for the tag-filtered keyset shape: it proves the
  scan is BOUNDED (cost scales with the selective residual, not the corpus), so a
  regression that turns the cursor into a heap filter over the whole tenant corpus —
  which `refute_seq_scan` alone would NOT catch (it'd still be a Bitmap/Index scan, just
  an unbounded one) — trips this instead. Pick `max_rows` as a small multiple of the
  residual's expected selectivity, comfortably below the corpus size.
  """
  def assert_scan_rows_below(queryable_or_sql, max_rows) when is_integer(max_rows) do
    assert_fresh_stats!()
    {root, raw} = explain_json(queryable_or_sql)
    scans = article_scan_nodes(root)

    over = Enum.filter(scans, &(is_number(&1.rows) and &1.rows >= max_rows))

    cond do
      scans == [] ->
        raise ExUnit.AssertionError,
          message: "Plan never reaches `articles` — cannot judge scan rows. Plan:\n#{elide(raw)}"

      over != [] ->
        raise ExUnit.AssertionError,
          message:
            "Expected every `articles` scan estimate < #{max_rows} (bounded by residual " <>
              "selectivity), but got #{inspect(Enum.map(over, & &1.rows))} — an unbounded scan " <>
              "over the corpus. Plan:\n#{elide(raw)}"

      true ->
        :ok
    end
  end

  @doc """
  Asserts the plan reaches `articles` via the given index `name` somewhere (an
  `Index Scan`, `Index Only Scan`, or `Bitmap Index Scan` naming it). Proves a
  selective index actually drives the scan (e.g. the `tags` GIN bounds a tag-filtered
  keyset query, and the keyset btree applies the cursor) rather than the planner
  reading the corpus and filtering in the heap.
  """
  def assert_index_used(queryable_or_sql, name) when is_binary(name) do
    {root, raw} = explain_json(queryable_or_sql)

    if name in index_names(root) do
      :ok
    else
      raise ExUnit.AssertionError,
        message:
          "Expected the plan to use index #{inspect(name)}, but it does not appear. " <>
            "Plan:\n#{elide(raw)}"
    end
  end

  @doc """
  Asserts `articles` is reached by EXACTLY ONE scan node, which is an `Index Scan`
  (or `Index Only Scan`) on an HNSW index (`pg_am.amname='hnsw'`, verified via catalog,
  not a name match). A sibling/outer full-scan on `articles` therefore cannot hide
  behind a present-but-unused HNSW node (AC-27.2.2/.3). Implies `refute_full_scan/1`.
  """
  def assert_hnsw_index(queryable_or_sql) do
    assert_fresh_stats!()
    {root, raw} = explain_json(queryable_or_sql)
    scans = article_scan_nodes(root)

    case scans do
      [%{node_type: type, index_name: idx}] when type in ["Index Scan", "Index Only Scan"] ->
        unless idx && hnsw_index?(idx) do
          raise ExUnit.AssertionError,
            message:
              "Expected the single `articles` scan to be an Index Scan on an HNSW index " <>
                "(amname='hnsw'); got index=#{inspect(idx)}. Plan:\n#{elide(raw)}"
        end

        :ok

      [] ->
        raise ExUnit.AssertionError,
          message: "Plan never reaches `articles`. Plan:\n#{elide(raw)}"

      [one] ->
        raise ExUnit.AssertionError,
          message:
            "Expected the `articles` scan to be an HNSW Index Scan, got #{inspect(one.node_type)}. " <>
              "Plan:\n#{elide(raw)}"

      many ->
        raise ExUnit.AssertionError,
          message:
            "Expected EXACTLY ONE scan on `articles` (the HNSW index), got #{length(many)}: " <>
              "#{inspect(Enum.map(many, & &1.node_type))} — a sibling full-scan could hide a " <>
              "full-corpus read. Plan:\n#{elide(raw)}"
    end
  end

  @doc """
  Raises unless `articles` holds real, analyzed rows — verified by an ACTUAL
  `count(*)` (reflecting committed reality, not autovacuum's lazy/sticky/cross-tenant
  `n_live_tup` estimate, which is blind to stale-high) AND a non-null `last_analyze`.
  Prevents a plan assertion from running against an unseeded/empty or unanalyzed corpus
  (AC-27.2.5). ScaleSeed already asserts `last_analyze` ADVANCED for the current run.
  """
  def assert_fresh_stats! do
    %{rows: [[real_count]]} = AdminRepo.query!("SELECT count(*) FROM articles")

    %{rows: [[last_analyze, last_autoanalyze]]} =
      AdminRepo.query!(
        "SELECT last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE relname = 'articles'"
      )

    cond do
      is_nil(real_count) or real_count <= 0 ->
        raise ExUnit.AssertionError,
          message:
            "Plan assertion ran against an EMPTY `articles` (committed count=#{inspect(real_count)}). " <>
              "Seed via Loopctl.Knowledge.ScaleSeed (unboxed, committed) first."

      is_nil(last_analyze) and is_nil(last_autoanalyze) ->
        raise ExUnit.AssertionError,
          message:
            "Plan assertion ran against an UNANALYZED `articles` (no last_analyze). " <>
              "ScaleSeed runs + verifies ANALYZE; run it before asserting."

      true ->
        :ok
    end
  end

  @doc """
  Captures the SQL+params of every AdminRepo/Repo query emitted while `fun` runs, via a
  `[:loopctl, :repo, :query]` / `[:loopctl, :admin_repo, :query]` telemetry handler.
  Returns `[{sql, params}, ...]` in execution order. Use it to obtain the request path's
  ACTUAL query and prove a plan assertion runs the SAME SQL+params it emits — not an
  independently re-constructed query (AC-27.2.4).

  Capture is scoped to the CURRENT process: query telemetry fires in the process that
  issued the query, so a direct context call and an inline `Phoenix.ConnTest` request
  (which runs in the test process) are captured, while concurrent async tests' queries
  are dropped. If the query under test ever runs off-process (a `Task`, a spawned job),
  nothing is captured and `only_query_matching/2` raises (fails closed, never silent).
  """
  def capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}
    events = [[:loopctl, :repo, :query], [:loopctl, :admin_repo, :query]]

    :telemetry.attach_many(
      handler_id,
      events,
      fn _event, _measure, meta, _ ->
        if self() == test_pid, do: send(test_pid, {ref, meta.query, meta.params})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, [])
  end

  defp drain(ref, acc) do
    receive do
      {^ref, sql, params} -> drain(ref, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  From captured queries, returns the single `{sql, params}` whose SQL matches `pattern`
  (a Regex or substring). Raises if zero or more than one match — the caller wants
  exactly the query under test (e.g. the cosine ORDER BY with the article_links anti-join).
  """
  def only_query_matching(captured, pattern) do
    matches =
      Enum.filter(captured, fn {sql, _} ->
        case pattern do
          %Regex{} -> Regex.match?(pattern, sql)
          s when is_binary(s) -> String.contains?(sql, s)
        end
      end)

    case matches do
      [one] ->
        one

      [] ->
        raise ExUnit.AssertionError,
          message: "No captured query matched #{inspect(pattern)} (captured #{length(captured)})"

      many ->
        raise ExUnit.AssertionError,
          message: "Expected exactly one query matching #{inspect(pattern)}, got #{length(many)}"
    end
  end

  # --- internals ---

  # Runs EXPLAIN (FORMAT JSON) and returns {root_plan_node_map, raw_text_for_messages}.
  defp explain_json({sql, params}) when is_binary(sql) and is_list(params) do
    %{rows: rows} = AdminRepo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
    # FORMAT JSON returns a single row whose first column is a JSON array [{"Plan": {...}}].
    decoded =
      rows
      |> List.first()
      |> List.first()
      |> decode_json()

    root = decoded |> List.first() |> Map.fetch!("Plan")
    {root, Jason.encode!(decoded)}
  end

  defp explain_json(queryable) do
    {sql, params} = SQL.to_sql(:all, AdminRepo, queryable)
    explain_json({sql, params})
  end

  defp decode_json(v) when is_binary(v), do: Jason.decode!(v)
  defp decode_json(v), do: v

  # Walk the plan tree; collect every node that scans the `articles` relation, with its
  # Node Type and (if any) Index Name. Covers Seq/Index/Index Only/Bitmap Heap scans.
  defp article_scan_nodes(node) when is_map(node) do
    here =
      if node["Relation Name"] == "articles" do
        [
          %{
            node_type: node["Node Type"],
            index_name: node["Index Name"],
            rows: node["Plan Rows"]
          }
        ]
      else
        []
      end

    children =
      node
      |> Map.get("Plans", [])
      |> Enum.flat_map(&article_scan_nodes/1)

    here ++ children
  end

  # Like `article_scan_nodes/1` but matches any relation whose name STARTS WITH
  # `prefix` (for partitioned tables: the parent `audit_log` plus child partitions
  # `audit_log_y2026m06`, all of which EXPLAIN names as the Relation Name on the scan
  # node). Returns the same `%{node_type, index_name, rows}` shape.
  defp relation_scan_nodes(node, prefix) when is_map(node) do
    name = node["Relation Name"]

    here =
      if is_binary(name) and String.starts_with?(name, prefix) do
        [
          %{
            node_type: node["Node Type"],
            index_name: node["Index Name"],
            rows: node["Plan Rows"],
            relation: name
          }
        ]
      else
        []
      end

    children =
      node
      |> Map.get("Plans", [])
      |> Enum.flat_map(&relation_scan_nodes(&1, prefix))

    here ++ children
  end

  # Collect every "Index Name" anywhere in the plan tree (Index Scan, Index Only Scan,
  # Bitmap Index Scan — the last has no "Relation Name", only "Index Name").
  defp index_names(node) when is_map(node) do
    here = if name = node["Index Name"], do: [name], else: []

    children =
      node
      |> Map.get("Plans", [])
      |> Enum.flat_map(&index_names/1)

    here ++ children
  end

  # Is `name` an HNSW index? Verify via pg_am, not the name string (AC-27.2.3).
  defp hnsw_index?(name) do
    %{rows: rows} =
      AdminRepo.query!(
        """
        SELECT am.amname
        FROM pg_class i
        JOIN pg_am am ON am.oid = i.relam
        WHERE i.relname = $1
        """,
        [name]
      )

    match?([["hnsw"]], rows)
  end

  # Elide vector literals so a failing plan is readable and leaks no embedding. Covers
  # `'[...]'::vector` and `::vector(1536)` casts; params are bound so the normal path has
  # no inline vector at all.
  defp elide(plan) do
    plan
    |> String.replace(~r/'\[[-0-9eE.,\s]+\]'(::(?:half)?vector(?:\(\d+\))?)?/, "'[…]'\\1")
    |> String.slice(0, 4_000)
  end
end
