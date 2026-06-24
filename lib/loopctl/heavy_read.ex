defmodule Loopctl.HeavyRead do
  @moduledoc """
  The ONLY sanctioned entry point for heavy, BYPASSRLS reads (US-27.11).

  `Loopctl.HeavyReadRepo` has BYPASSRLS, so RLS does not scope its queries — the
  `tenant_id` predicate is the only thing standing between tenant A and tenant
  B's rows. This module makes forgetting that predicate impossible by
  construction (AC-27.11.4):

    * every function REQUIRES a `tenant_id` (a binary) as its first argument, and
    * it refuses (raises `ArgumentError`) any query that does not contain a
      `tenant_id == ^param` EQUALITY (in a WHERE / HAVING / JOIN-ON position,
      including inside a from/join/where-in subquery) whose bound value is the
      `tenant_id` argument that was passed in.

  ## Exactly what the guard proves (and what it does NOT)

  It proves: *there is an equality `x.tenant_id == ^tenant_id` in a filter
  position, bound to the caller's `tenant_id`.* This is stronger than "a
  tenant_id filter exists" — `tenant_id != ^x`, `is_nil(tenant_id)`, or an
  equality to a DIFFERENT tenant's id are all rejected.

  It does NOT prove the query is otherwise correct (a join could widen scope, an
  `OR` could re-admit rows). It is a mandatory necessary gate against the single
  most common BYPASSRLS footgun — forgetting/mis-scoping the tenant predicate —
  not a proof of full query correctness.

  Constraint: the predicate MUST be an Ecto field comparison `x.tenant_id ==
  ^id`. A tenant filter expressed as a raw `fragment("tenant_id = ?", ^id)` is
  NOT recognized (the AST carries no `:tenant_id` field node) and will be
  rejected — express tenant scoping through the schema field, not SQL text.

  A companion build guard (`test/loopctl/heavy_read_guard_test.exs`) fails if any
  `lib/` module other than this one reaches `Loopctl.HeavyReadRepo` directly, so
  the only path to the heavy-read pool is through this tenant-checked wrapper.

  ## Repo resolution (config-based DI)

  The backing repo is resolved via `Application.get_env(:loopctl, :heavy_read_repo,
  Loopctl.HeavyReadRepo)`. Production/dev use the dedicated `HeavyReadRepo` pool.
  The test env points it at `Loopctl.AdminRepo` (config/test.exs) so heavy reads
  share the sandbox connection that fixtures insert through — otherwise a
  separate-pool repo would run in its own sandbox transaction and never see the
  test's uncommitted rows. The structural guard and tenant-isolation behavior are
  repo-agnostic and are fully exercised regardless of which repo backs it.

  Because of that DI, the routed knowledge queries run against `AdminRepo` in the
  test suite; the dedicated `HeavyReadRepo` pool's `:parameters` (statement_timeout)
  are exercised directly by `heavy_read_repo_test.exs` /
  `heavy_read_pool_isolation_test.exs` (incl. a real Ecto query canceled by the
  pool timeout). True OS-level pool starvation is not reproducible under Sandbox,
  so TC-27.11.1's concurrency guarantee is structural (separate pools + bounded
  hold) and is re-verified under load per docs/runbooks/knowledge-scale.md.
  """

  @doc "Resolved heavy-read repo (DI). `HeavyReadRepo` in prod/dev, `AdminRepo` in test."
  @spec repo() :: module()
  def repo, do: Application.get_env(:loopctl, :heavy_read_repo, Loopctl.HeavyReadRepo)

  @doc """
  Like `Repo.all/2`, but requires a `tenant_id` and a query that is scoped to it
  (`x.tenant_id == ^tenant_id`). Raises `ArgumentError` if `tenant_id` is not a
  binary or the query is not so scoped.
  """
  @spec all(binary(), Ecto.Queryable.t(), keyword()) :: [term()]
  def all(tenant_id, queryable, opts \\ []) do
    repo().all(guard!(tenant_id, queryable), opts)
  end

  @doc "Like `Repo.one/2`, with the same tenant-scoping guard as `all/3`."
  @spec one(binary(), Ecto.Queryable.t(), keyword()) :: term() | nil
  def one(tenant_id, queryable, opts \\ []) do
    repo().one(guard!(tenant_id, queryable), opts)
  end

  @doc """
  Like `Repo.stream/2`, with the same tenant-scoping guard. Must run inside a
  `transaction/2` (Ecto streams require an enclosing transaction). Used by the
  US-27.16 streamed export.
  """
  @spec stream(binary(), Ecto.Queryable.t(), keyword()) :: Enumerable.t()
  def stream(tenant_id, queryable, opts \\ []) do
    repo().stream(guard!(tenant_id, queryable), opts)
  end

  @doc """
  Delegates to the heavy-read repo's `transaction/2` (for streamed reads).

  Accepts a `:statement_timeout` option (milliseconds; `0` = unlimited). When
  given, the transaction first issues `SET LOCAL statement_timeout = <ms>`, which
  scopes the override to THIS transaction only — so a long-held streamed export
  (US-27.16) can run past the pool-level fast-read `statement_timeout` without
  relaxing it for everyone else. Only supported with a function (not an
  `Ecto.Multi`).
  """
  @spec transaction((-> any()) | (module() -> any()) | Ecto.Multi.t(), keyword()) ::
          {:ok, any()} | {:error, any()}
  def transaction(fun_or_multi, opts \\ []) do
    case Keyword.pop(opts, :statement_timeout) do
      {nil, opts} ->
        repo().transaction(fun_or_multi, opts)

      {ms, opts} when is_integer(ms) and ms >= 0 and is_function(fun_or_multi) ->
        repo().transaction(
          fn ->
            repo().query!("SET LOCAL statement_timeout = #{ms}")
            invoke(fun_or_multi)
          end,
          opts
        )

      {ms, _opts} ->
        raise ArgumentError,
              ":statement_timeout (got #{inspect(ms)}) requires a non-negative integer and a " <>
                "function transaction body (not an Ecto.Multi)"
    end
  end

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke(fun) when is_function(fun, 1), do: fun.(repo())

  # --- structural tenant guard ---

  defp guard!(tenant_id, queryable) when is_binary(tenant_id) do
    query = Ecto.Queryable.to_query(queryable)

    unless scoped_to_tenant?(query, tenant_id) do
      raise ArgumentError,
            "Loopctl.HeavyRead refuses a query not scoped to the given tenant (BYPASSRLS pool, " <>
              "cross-tenant leak risk). The query must contain `x.tenant_id == ^tenant_id` " <>
              "(equality, bound to the passed tenant_id) in a where/having/join-on, possibly in " <>
              "a subquery. Query: #{inspect(query, limit: 12)}"
    end

    query
  end

  defp guard!(tenant_id, _queryable) do
    raise ArgumentError,
          "Loopctl.HeavyRead requires a binary tenant_id as the first argument, got: " <>
            inspect(tenant_id)
  end

  @doc false
  # Structural shape check (no value binding): does the query contain a
  # `x.tenant_id == ^param` equality in a filter position (incl. subqueries)?
  # Exposed for the guard unit tests.
  def filters_by_tenant?(queryable) do
    queryable |> Ecto.Queryable.to_query() |> tenant_eq_pins() |> Enum.any?()
  end

  # True iff some `x.tenant_id == ^param` equality in a filter position is bound to
  # the value `tenant_id` (not merely present, and not bound to another tenant).
  defp scoped_to_tenant?(%Ecto.Query{} = query, tenant_id) do
    query
    |> tenant_eq_pins()
    |> Enum.any?(fn {params, idx} ->
      match?({^tenant_id, _type}, Enum.at(params || [], idx))
    end)
  end

  # Every `{params, pin_index}` for a `x.tenant_id == ^pin` equality found in a
  # filter position, recursing into from/join/where-in subqueries.
  defp tenant_eq_pins(%Ecto.Query{} = query) do
    query
    |> tenant_filter_exprs()
    |> Enum.flat_map(fn %{expr: expr, params: params} ->
      expr |> tenant_eq_indices() |> Enum.map(&{params, &1})
    end)
  end

  # BooleanExpr/QueryExpr structs (each carries :expr + :params) in filter
  # positions, plus those reachable through from/join/where-in subqueries.
  defp tenant_filter_exprs(%Ecto.Query{} = query) do
    filters = query.wheres ++ query.havings

    own =
      filters ++ (query.joins |> Enum.map(& &1.on) |> Enum.reject(&is_nil/1))

    subqueries =
      [from_source(query.from) | Enum.map(query.joins, &Map.get(&1, :source))] ++
        Enum.flat_map(filters, &(Map.get(&1, :subqueries) || []))

    own ++ Enum.flat_map(subqueries, &subquery_filter_exprs/1)
  end

  defp from_source(%{source: source}), do: source
  defp from_source(_), do: nil

  defp subquery_filter_exprs(%Ecto.SubQuery{query: q}), do: tenant_filter_exprs(q)
  defp subquery_filter_exprs(_), do: []

  # Pin indices `i` where the expr contains `x.tenant_id == ^i` (either operand
  # order). Only the `==` operator counts — `!=`/`is_nil`/etc. are not scoping.
  defp tenant_eq_indices({:==, _, [l, r]}) do
    here =
      cond do
        tenant_field?(l) and pin?(r) -> [pin_index(r)]
        tenant_field?(r) and pin?(l) -> [pin_index(l)]
        true -> []
      end

    here ++ tenant_eq_indices(l) ++ tenant_eq_indices(r)
  end

  defp tenant_eq_indices(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&tenant_eq_indices/1)

  defp tenant_eq_indices(list) when is_list(list),
    do: Enum.flat_map(list, &tenant_eq_indices/1)

  defp tenant_eq_indices(_), do: []

  defp tenant_field?({{:., _, [_, :tenant_id]}, _, _}), do: true
  defp tenant_field?(_), do: false

  defp pin?({:^, _, [_]}), do: true
  defp pin?(_), do: false

  defp pin_index({:^, _, [i]}), do: i
end
