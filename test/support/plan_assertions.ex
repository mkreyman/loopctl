defmodule Loopctl.PlanAssertions do
  @moduledoc """
  Query-plan assertions for scale tests (US-27.2).

  The point of this module is to catch the exact false-green that shipped the
  `suggested_links` 500 three times: a query whose ORDER BY is index-*eligible* but
  which the planner does NOT actually use at prod scale (it Seq-Scans the whole
  corpus + Sorts, then times out).

  CRITICAL: these assertions run `EXPLAIN` WITHOUT forcing the planner
  (`enable_seqscan`/`enable_sort` are left at their defaults). Forcing the planner
  proves index *eligibility*, not that the planner *chooses* the index — that
  distinction is precisely what produced false confidence in #172. So these are
  meaningful ONLY against a committed, ANALYZEd, ≥prod-scale corpus
  (`Loopctl.Knowledge.ScaleSeed`); at toy scale the planner Seq-Scans happily and
  the assertion would be a lie. `assert_fresh_stats!/0` enforces that precondition.

  Failure signal is the literal `Seq Scan on articles` node (AC-27.2.2). A `Sort`
  node is NOT itself a failure — the verified suggested_links shape legitimately
  sorts the small post-ANN candidate pool — so Sort is advisory only.
  """

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo

  @articles_seq_scan ~r/Seq Scan on articles\b/i

  @doc """
  Asserts the planner does NOT reach `articles` via a full `Seq Scan` for the given
  query — i.e. the corpus is read through an index (the HNSW path for cosine ORDER BY).

  Accepts an Ecto queryable or a `{sql, params}` tuple (the latter lets a caller pass
  the controller's captured SQL+params, AC-27.2.4). Raises `ExUnit.AssertionError`
  with the offending plan (vector literals elided) when a `Seq Scan on articles`
  appears. Runs against the planner's natural choice — no `enable_seqscan=off`.
  """
  def refute_full_scan(queryable_or_sql) do
    assert_fresh_stats!()
    plan = explain(queryable_or_sql)

    if Regex.match?(@articles_seq_scan, plan) do
      raise ExUnit.AssertionError,
        message:
          "Expected `articles` to be read via an index, but the plan contains a full " <>
            "`Seq Scan on articles` (the #170/#172 prod-500 shape). Plan:\n#{elide(plan)}"
    end

    :ok
  end

  @doc """
  Asserts the plan reaches `articles` via an `Index Scan using <idx>` where `<idx>` is
  an HNSW index (`pg_am.amname = 'hnsw'`) — not merely a name that looks right
  (AC-27.2.3). Implies `refute_full_scan/1`.
  """
  def assert_hnsw_index(queryable_or_sql) do
    refute_full_scan(queryable_or_sql)
    plan = explain(queryable_or_sql)

    index_name =
      case Regex.run(~r/Index Scan using (\S+) on articles\b/i, plan) do
        [_, name] -> name
        _ -> nil
      end

    unless index_name && hnsw_index?(index_name) do
      raise ExUnit.AssertionError,
        message:
          "Expected an `Index Scan using <hnsw index> on articles` (amname='hnsw'), " <>
            "got index=#{inspect(index_name)} (hnsw? #{index_name && hnsw_index?(index_name)}). " <>
            "Plan:\n#{elide(plan)}"
    end

    :ok
  end

  @doc """
  Raises unless `articles` has fresh planner statistics reflecting a real corpus —
  `n_live_tup > 0` and `last_analyze`/`last_autoanalyze` set (US-27.1's ANALYZE).
  Prevents a plan assertion from producing a misleading pass/fail against an
  unanalyzed (n≈0) table (AC-27.2.5).
  """
  def assert_fresh_stats! do
    %{rows: [[live, last_analyze, last_autoanalyze]]} =
      AdminRepo.query!(
        "SELECT n_live_tup, last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE relname = 'articles'"
      )

    cond do
      is_nil(live) or live <= 0 ->
        raise ExUnit.AssertionError,
          message:
            "Plan assertion ran against `articles` with n_live_tup=#{inspect(live)} — the " <>
              "corpus is not seeded/committed. Seed via Loopctl.Knowledge.ScaleSeed (unboxed) first."

      is_nil(last_analyze) and is_nil(last_autoanalyze) ->
        raise ExUnit.AssertionError,
          message:
            "Plan assertion ran against an UNANALYZED `articles` (no last_analyze). " <>
              "ScaleSeed runs ANALYZE; run it before asserting, or stats are stale (n≈0 planner)."

      true ->
        :ok
    end
  end

  @doc """
  Captures the SQL+params of every AdminRepo/Repo query emitted while `fun` runs, by
  attaching a one-shot `[:loopctl, :repo, :query]` (and AdminRepo) telemetry handler.
  Returns `[{sql, params}, ...]` in execution order. Use it to obtain the controller's
  ACTUAL query and prove a plan assertion runs the SAME SQL+params the request path
  emits — not an independently re-constructed query (AC-27.2.4).
  """
  def capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    events = [
      [:loopctl, :repo, :query],
      [:loopctl, :admin_repo, :query]
    ]

    # Query telemetry fires in the process that issued the query. Capture ONLY queries
    # from the current process (the test, or the inline ConnTest request) — otherwise a
    # global handler also grabs concurrent async tests' queries (flaky "got 2").
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
  From captured queries, returns the single one whose SQL matches `pattern` (a Regex or
  substring). Raises if zero or more than one match — the caller wants exactly the
  query under test (e.g. the cosine ORDER BY with the article_links anti-join).
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

  defp explain({sql, params}) when is_binary(sql) and is_list(params) do
    %{rows: rows} = AdminRepo.query!("EXPLAIN " <> sql, params)
    Enum.map_join(rows, "\n", fn [line] -> line end)
  end

  defp explain(queryable) do
    {sql, params} = SQL.to_sql(:all, AdminRepo, queryable)
    explain({sql, params})
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

  # Elide 1536-float vector literals so a failing plan is readable and leaks no embedding.
  defp elide(plan) do
    plan
    |> String.replace(~r/'\[[-0-9eE.,\s]+\]'::vector/, "'[…]'::vector")
    |> String.slice(0, 4_000)
  end
end
