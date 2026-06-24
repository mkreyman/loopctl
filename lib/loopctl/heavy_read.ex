defmodule Loopctl.HeavyRead do
  @moduledoc """
  The ONLY sanctioned entry point for heavy, BYPASSRLS reads (US-27.11).

  `Loopctl.HeavyReadRepo` has BYPASSRLS, so RLS does not scope its queries — the
  `tenant_id` predicate is the only thing standing between tenant A and tenant
  B's rows. This module makes forgetting that predicate **impossible by
  construction** (AC-27.11.4):

    * every function REQUIRES a `tenant_id` (a binary) as its first argument, and
    * it refuses (raises `ArgumentError`) any query that does not filter by
      `tenant_id` in a WHERE / HAVING / JOIN-ON position — including inside a
      subquery used as the FROM source or a join source (the suggested-links
      candidate query filters tenant in its inner subquery).

  A companion build guard (`test/loopctl/heavy_read_guard_test.exs`) fails if any
  `lib/` module other than this one calls `Loopctl.HeavyReadRepo.{all,one,stream}`
  directly, so the only path to the heavy-read pool is through this tenant-checked
  wrapper.

  ## Repo resolution (config-based DI)

  The backing repo is resolved via `Application.get_env(:loopctl, :heavy_read_repo,
  Loopctl.HeavyReadRepo)`. Production/dev use the dedicated `HeavyReadRepo` pool.
  The test env points it at `Loopctl.AdminRepo` (config/test.exs) so heavy reads
  share the sandbox connection that fixtures insert through — otherwise a
  separate-pool repo would run in its own sandbox transaction and never see the
  test's uncommitted rows. The structural guard and tenant-isolation behavior are
  repo-agnostic and are fully exercised regardless of which repo backs it.
  """

  @doc "Resolved heavy-read repo (DI). `HeavyReadRepo` in prod/dev, `AdminRepo` in test."
  @spec repo() :: module()
  def repo, do: Application.get_env(:loopctl, :heavy_read_repo, Loopctl.HeavyReadRepo)

  @doc """
  Like `Repo.all/2`, but requires a `tenant_id` and a tenant-scoped query.
  Raises `ArgumentError` if `tenant_id` is not a binary or the query has no
  `tenant_id` filter.
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

  @doc "Delegates to the heavy-read repo's `transaction/2` (for streamed reads)."
  @spec transaction((-> any()) | Ecto.Multi.t(), keyword()) :: {:ok, any()} | {:error, any()}
  def transaction(fun_or_multi, opts \\ []) do
    repo().transaction(fun_or_multi, opts)
  end

  # --- structural tenant guard ---

  defp guard!(tenant_id, queryable) when is_binary(tenant_id) do
    query = Ecto.Queryable.to_query(queryable)

    unless filters_by_tenant?(query) do
      raise ArgumentError,
            "Loopctl.HeavyRead refuses a query with no tenant_id filter (BYPASSRLS pool, " <>
              "cross-tenant leak risk). Add `where: x.tenant_id == ^tenant_id` to the query " <>
              "(or its subquery). Query: #{inspect(query, limit: 12)}"
    end

    query
  end

  defp guard!(tenant_id, _queryable) do
    raise ArgumentError,
          "Loopctl.HeavyRead requires a binary tenant_id as the first argument, got: " <>
            inspect(tenant_id)
  end

  @doc false
  # Exposed for the structural-guard unit test: does this query filter by tenant_id
  # in a where/having/join-on (incl. inside a from/join subquery)?
  def filters_by_tenant?(%Ecto.Query{} = query) do
    query
    |> filter_exprs()
    |> Enum.any?(&references_tenant_id?/1)
  end

  def filters_by_tenant?(queryable),
    do: queryable |> Ecto.Queryable.to_query() |> filters_by_tenant?()

  # Every expression in a FILTERING position, recursing into from/join subqueries.
  defp filter_exprs(%Ecto.Query{} = query) do
    own =
      Enum.map(query.wheres, & &1.expr) ++
        Enum.map(query.havings, & &1.expr) ++
        (query.joins |> Enum.map(& &1.on) |> Enum.reject(&is_nil/1) |> Enum.map(& &1.expr))

    subquery_sources =
      [from_source(query.from) | Enum.map(query.joins, &Map.get(&1, :source))]

    own ++ Enum.flat_map(subquery_sources, &subquery_filter_exprs/1)
  end

  defp from_source(%{source: source}), do: source
  defp from_source(_), do: nil

  defp subquery_filter_exprs(%Ecto.SubQuery{query: q}), do: filter_exprs(q)
  defp subquery_filter_exprs(_), do: []

  # Deep-scan a compiled query expression for a `x.tenant_id` field reference,
  # i.e. the `{:., _, [_binding, :tenant_id]}` node Ecto emits for `a.tenant_id`.
  defp references_tenant_id?({:., _, [_, :tenant_id]}), do: true

  defp references_tenant_id?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> references_tenant_id?()

  defp references_tenant_id?(list) when is_list(list),
    do: Enum.any?(list, &references_tenant_id?/1)

  defp references_tenant_id?(_), do: false
end
