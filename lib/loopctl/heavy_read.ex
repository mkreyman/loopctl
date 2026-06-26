defmodule Loopctl.HeavyRead do
  @moduledoc """
  The ONLY sanctioned entry point for heavy, BYPASSRLS reads (US-27.11).

  `Loopctl.HeavyReadRepo` has BYPASSRLS, so RLS does not scope its queries — the
  `tenant_id` predicate is the only thing standing between tenant A and tenant
  B's rows. This module makes mis-scoping that predicate fail fast (AC-27.11.4).

  ## What the guard proves

  A query is accepted only if EVERY base-table source it reads from — the `from`
  table AND every joined table — is constrained by a CONJUNCTIVE
  `x.tenant_id == ^tenant_id` equality on THAT source's binding, bound to the
  `tenant_id` argument passed in; subquery sources (from/join/where-in) are
  required to be scoped the same way, recursively. Concretely this rejects:

    * an unscoped `from` (the primary table read without a tenant filter), even
      if a *joined* table is scoped;
    * a joined table with no tenant filter on it (its rows could cross tenants);
    * a tenant predicate that is OR-ed with a broadening condition
      (`tenant_id == ^t or status == :published`) — the tenant predicate must be
      AND-combined, not re-admitting other tenants;
    * `tenant_id != ^x`, `is_nil(tenant_id)`, or an equality to a DIFFERENT
      tenant than the caller.

  ## Limits (not proven)

  This is a strong necessary gate, not a proof of full query correctness. The
  tenant predicate MUST be an Ecto field comparison `x.tenant_id == ^id` (a raw
  `fragment("tenant_id = ?", ^id)` is not recognized and will be rejected — scope
  through the schema field). Sources that are neither a schema table nor a
  subquery (a raw `fragment` from, or a CTE reference) are not structurally
  validated — express tenant scoping in the outer query or a from/join subquery
  rather than a CTE source.

  A companion build guard (`test/loopctl/heavy_read_guard_test.exs`) fails if any
  `lib/` module other than this one reaches `Loopctl.HeavyReadRepo` directly, so
  the only path to the heavy-read pool is through this tenant-checked wrapper.

  ## Repo resolution (config-based DI)

  The backing repo is resolved via `Application.get_env(:loopctl, :heavy_read_repo,
  Loopctl.HeavyReadRepo)`. Production/dev use the dedicated `HeavyReadRepo` pool.
  The test env points it at `Loopctl.AdminRepo` (config/test.exs) so heavy reads
  share the sandbox connection that fixtures insert through. The guard and tenant
  isolation are repo-agnostic and fully exercised regardless of which repo backs
  it; the per-read `SET LOCAL statement_timeout` mechanism is exercised directly on the
  dedicated pool by `heavy_read_repo_test.exs` / `heavy_read_pool_isolation_test.exs` (incl.
  a real Ecto query canceled by the timeout). (US-27.13: the timeout is applied per-read via
  SET LOCAL, NOT a startup `:parameters` — pgbouncer rejects the latter with 08P01.) True
  OS-level pool starvation is not
  reproducible under Sandbox, so TC-27.11.1's concurrency guarantee is structural
  (separate pools + bounded hold) and is re-verified under load per
  docs/runbooks/knowledge-scale.md.
  """

  @doc "Resolved heavy-read repo (DI). `HeavyReadRepo` in prod/dev, `AdminRepo` in test."
  @spec repo() :: module()
  def repo, do: Application.get_env(:loopctl, :heavy_read_repo, Loopctl.HeavyReadRepo)

  @doc """
  Per-read options for a heavy endpoint (US-27.4): the 15s CLIENT timeout backstop plus
  the SERVER-SIDE `:statement_timeout` — the per-endpoint override (config
  `:heavy_read_statement_timeout_overrides`, e.g. `%{suggested_links: 5_000}`) if set,
  ELSE the pool-wide default (`:heavy_read_statement_timeout_ms`, 10s). It is ALWAYS
  present, so every heavy read is wrapped in a `SET LOCAL statement_timeout` transaction.

  This replaced a connection-startup `parameters: [statement_timeout: ...]` lever
  (US-27.11) that Fly MPG's pgbouncer rejected with `08P01 unsupported startup
  parameter`, crash-looping the whole HeavyReadRepo pool and 503ing every heavy endpoint
  (US-27.13). `SET LOCAL` inside a transaction is the pgbouncer-safe way to set a
  server-side statement_timeout. Also passes the endpoint key via `telemetry_options` so
  slow-query logs can trace which endpoint triggered the query.

  This is the SINGLE source of truth for heavy-read opts — every consumer
  (`Loopctl.Knowledge`, `Loopctl.Audit`) builds opts via this function so the
  `[timeout, telemetry_options, statement_timeout]` shape can't drift between callers.
  Known endpoints: `:suggested_links`, `:semantic_search`, `:distant_pairs`, `:novelty`,
  `:enumeration`, `:change_feed`, `:vector_search` (the shared kNN helper path).
  """
  @spec opts(atom()) :: keyword()
  def opts(endpoint) when is_atom(endpoint) do
    base = [timeout: 15_000, telemetry_options: [endpoint: endpoint]]
    Keyword.put(base, :statement_timeout, statement_timeout_for(endpoint))
  end

  # The per-endpoint override if a positive int, else the pool-wide default. Always a
  # positive int → every heavy read runs under a SET LOCAL statement_timeout (the
  # pgbouncer-safe replacement for the rejected startup `:parameters`).
  defp statement_timeout_for(endpoint) do
    case statement_timeout_override(endpoint) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default_statement_timeout()
    end
  end

  # The pool-wide default server-side statement_timeout (ms). Defensive: a missing or
  # mis-typed (`nil`/0/negative) `:heavy_read_statement_timeout_ms` falls back to 10s rather
  # than yielding a non-positive value that would defeat the always-timed invariant.
  defp default_statement_timeout do
    case Application.get_env(:loopctl, :heavy_read_statement_timeout_ms, 10_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 10_000
    end
  end

  defp statement_timeout_override(endpoint) do
    :loopctl
    |> Application.get_env(:heavy_read_statement_timeout_overrides, %{})
    |> Map.get(endpoint)
  end

  @doc """
  Like `Repo.all/2`, but requires a `tenant_id` and a query whose every base-table
  source is scoped to it. Raises `ArgumentError` otherwise.

  A `:statement_timeout` (positive ms) option sets the server-side timeout for THIS read
  via a `SET LOCAL` inside a transaction (US-27.4). When omitted it defaults to the
  pool-wide `:heavy_read_statement_timeout_ms` (10s) — so EVERY heavy read is protected
  (there is no un-timed "pool default" path: pgbouncer rejects a startup-`:parameters`
  statement_timeout, so the timeout MUST be applied per-read via SET LOCAL — US-27.13).
  """
  @spec all(binary(), Ecto.Queryable.t(), keyword()) :: [term()]
  def all(tenant_id, queryable, opts \\ []) do
    # `Keyword.pop/3` with a default cleanly distinguishes "absent → pool default" from a
    # PRESENT value (which is validated as a positive int below) — unlike `st || default`,
    # which would silently treat an explicit `0` as truthy and an explicit `nil` as "use
    # default", muddying the always-timed contract.
    {st, opts} = Keyword.pop(opts, :statement_timeout, default_statement_timeout())
    query = guard!(tenant_id, queryable)
    with_statement_timeout(st, fn -> repo().all(query, opts) end)
  end

  @doc "Like `Repo.one/2`, with the same tenant-scoping guard and `:statement_timeout` as `all/3`."
  @spec one(binary(), Ecto.Queryable.t(), keyword()) :: term() | nil
  def one(tenant_id, queryable, opts \\ []) do
    {st, opts} = Keyword.pop(opts, :statement_timeout, default_statement_timeout())
    query = guard!(tenant_id, queryable)
    with_statement_timeout(st, fn -> repo().one(query, opts) end)
  end

  # Run `fun` under a per-read SET LOCAL statement_timeout. There is NO un-timed path:
  # `all/one` always resolve a positive default, and a non-positive/`nil` value (an explicit
  # mis-call) raises rather than silently running un-timed (US-27.13: every heavy read MUST
  # carry a server-side timeout since the pgbouncer-rejected startup `:parameters` lever is gone).
  defp with_statement_timeout(ms, fun) when is_integer(ms) and ms > 0 do
    case transaction(fun, statement_timeout: ms) do
      {:ok, result} ->
        result

      # A heavy read aborts only via an explicit Repo.rollback (the timeout CANCEL itself is
      # a raised Postgrex.Error that propagates as-is to the DBErrorBackstop). Keep the
      # message opaque — never interpolate the rollback reason, which could carry raw SQL /
      # vector text and defeat the US-27.3 sanitization contract.
      {:error, _reason} ->
        raise "heavy read aborted (transaction rolled back)"
    end
  end

  defp with_statement_timeout(ms, _fun) do
    raise ArgumentError,
          ":statement_timeout (got #{inspect(ms)}) must be a positive integer (ms)"
  end

  @doc """
  Like `Repo.stream/2`, with the same tenant-scoping guard. Must run inside a
  `transaction/2` — Ecto streams require an enclosing transaction (enumerating the
  returned stream outside one raises), which is also what scopes a per-transaction
  `SET LOCAL statement_timeout`.

  NB: the "every heavy read is timed" invariant applies to `all/3` / `one/3` (which
  default the timeout). `stream/3` and a bare `transaction/2` do NOT auto-apply one — a
  caller MUST pass `:statement_timeout` to `transaction/2` (this is the export lever) so the
  enclosed `stream/3` reads run timed. Don't add an un-timed `transaction/2` heavy read.

  NOTE: the US-27.16 streamed EXPORT does NOT use this — it pages with the US-27.9a
  keyset cursor via `all/3` (short read per page, connection RELEASED between pages)
  precisely to AVOID holding one transaction (and `xmin`) for the whole client-paced
  download. `stream/3` + `transaction/2` are reserved for a future async/Oban export
  job that builds to object storage off the request path.
  """
  @spec stream(binary(), Ecto.Queryable.t(), keyword()) :: Enumerable.t()
  def stream(tenant_id, queryable, opts \\ []) do
    repo().stream(guard!(tenant_id, queryable), opts)
  end

  @doc """
  Delegates to the heavy-read repo's `transaction/2` (for streamed reads).

  Accepts a `:statement_timeout` option (milliseconds; must be a POSITIVE integer).
  When given, the transaction first issues `SET LOCAL statement_timeout = <ms>`,
  scoping the override to THIS transaction only — so a long-held streamed export
  (US-27.16) can run past the pool-level fast-read `statement_timeout` without
  relaxing it for everyone else. `0`/unlimited is intentionally NOT allowed (an
  unbounded hold on the small heavy pool is a DoS surface — set an explicit upper
  bound). Only supported with a 0- or 1-arity function (not an `Ecto.Multi`).
  """
  @spec transaction((-> any()) | (module() -> any()) | Ecto.Multi.t(), keyword()) ::
          {:ok, any()} | {:error, any()}
  def transaction(fun_or_multi, opts \\ []) do
    case Keyword.pop(opts, :statement_timeout) do
      {nil, opts} ->
        repo().transaction(fun_or_multi, opts)

      {ms, opts}
      when is_integer(ms) and ms > 0 and
             (is_function(fun_or_multi, 0) or is_function(fun_or_multi, 1)) ->
        repo().transaction(
          fn ->
            repo().query!("SET LOCAL statement_timeout = #{ms}")
            invoke(fun_or_multi)
          end,
          opts
        )

      {ms, _opts} ->
        raise ArgumentError,
              ":statement_timeout (got #{inspect(ms)}) requires a POSITIVE integer (ms) and a " <>
                "0/1-arity function transaction body (not an Ecto.Multi, not 0/unlimited)"
    end
  end

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke(fun) when is_function(fun, 1), do: fun.(repo())

  # --- structural tenant guard ---

  defp guard!(tenant_id, queryable) when is_binary(tenant_id) do
    query = Ecto.Queryable.to_query(queryable)

    unless query_scoped?(query, {:value, tenant_id}) do
      raise ArgumentError,
            "Loopctl.HeavyRead refuses a query not fully scoped to the given tenant (BYPASSRLS " <>
              "pool, cross-tenant leak risk). Every base-table source (#{source_tables(query)}) " <>
              "must carry a conjunctive `x.tenant_id == ^tenant_id` equality bound to the passed " <>
              "tenant_id (no OR-bypass, no unscoped join)."
    end

    query
  end

  defp guard!(tenant_id, _queryable) do
    raise ArgumentError,
          "Loopctl.HeavyRead requires a binary tenant_id as the first argument, got: " <>
            inspect(tenant_id)
  end

  @doc false
  # Structural shape check (no value binding): would this query pass the guard for
  # SOME tenant? Exposed for the guard unit tests.
  def filters_by_tenant?(queryable) do
    queryable |> Ecto.Queryable.to_query() |> query_scoped?(:any)
  end

  # A query is scoped iff every base-table source has a conjunctive tenant equality
  # on its binding (matching the caller for `{:value, t}`, any pin for `:any`) and
  # every subquery source is itself scoped.
  defp query_scoped?(%Ecto.Query{} = query, mode) do
    scoped = scoped_bindings(query, mode)

    Enum.all?(source_bindings(query), fn
      {idx, :table} -> MapSet.member?(scoped, idx)
      {_idx, {:sub, sub}} -> query_scoped?(sub, mode)
      # Non-schema source (raw fragment from / CTE ref): not structurally validated.
      {_idx, :other} -> true
    end)
  end

  # Each source paired with its binding index (from = 0, joins = 1, 2, … in order).
  defp source_bindings(query) do
    from_b = {0, classify(query.from && query.from.source)}

    join_b =
      query.joins
      |> Enum.with_index(1)
      |> Enum.map(fn {j, i} -> {i, classify(Map.get(j, :source))} end)

    [from_b | join_b]
  end

  defp classify(%Ecto.SubQuery{query: q}), do: {:sub, q}
  defp classify({_table, schema}) when is_atom(schema) and not is_nil(schema), do: :table
  defp classify(_), do: :other

  # Binding indices constrained by a CONJUNCTIVE `x.tenant_id == ^pin` equality in a
  # where/having/join-on (a tenant equality nested under an OR does NOT count — it
  # can re-admit other tenants). For `{:value, t}` the pin must be bound to `t`.
  defp scoped_bindings(query, mode) do
    exprs =
      query.wheres ++
        query.havings ++
        (query.joins |> Enum.map(& &1.on) |> Enum.reject(&is_nil/1))

    Enum.reduce(exprs, MapSet.new(), fn %{expr: expr, params: params}, acc ->
      expr
      |> and_conjuncts()
      |> Enum.flat_map(&tenant_binding(&1, params, mode))
      |> Enum.into(acc)
    end)
  end

  defp and_conjuncts({:and, _, [l, r]}), do: and_conjuncts(l) ++ and_conjuncts(r)
  defp and_conjuncts(other), do: [other]

  defp tenant_binding({:==, _, [l, r]}, params, mode) do
    cond do
      (k = tenant_field_binding(l)) && pin?(r) && pin_matches?(r, params, mode) -> [k]
      (k = tenant_field_binding(r)) && pin?(l) && pin_matches?(l, params, mode) -> [k]
      true -> []
    end
  end

  defp tenant_binding(_, _, _), do: []

  defp tenant_field_binding({{:., _, [{:&, _, [k]}, :tenant_id]}, _, _}), do: k
  defp tenant_field_binding(_), do: nil

  defp pin?({:^, _, [_]}), do: true
  defp pin?(_), do: false

  defp pin_matches?({:^, _, [i]}, params, {:value, tenant_id}),
    do: match?({^tenant_id, _type}, Enum.at(params || [], i))

  defp pin_matches?(_, _, :any), do: true

  # Human-readable list of source names for the error — table names only, NO bound
  # params, so no embeddings / tenant ids / agent ids leak into logs (info disclosure).
  defp source_tables(query) do
    [query.from && query.from.source | Enum.map(query.joins, &Map.get(&1, :source))]
    |> Enum.flat_map(fn
      {table, schema} when is_atom(schema) and not is_nil(schema) -> [table]
      %Ecto.SubQuery{} -> ["<subquery>"]
      _ -> []
    end)
    |> Enum.join(", ")
  end
end
