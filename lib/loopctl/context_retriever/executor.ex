defmodule Loopctl.ContextRetriever.Executor do
  @moduledoc """
  The SECURITY BOUNDARY of Epic 30: turns a generated tool call (produced by the
  US-30.2 `ToolGenerator`) into a safe, parameterized, tenant-scoped Ecto query
  against a loopctl-internal backing table (`stories` / `projects` / `epics`).

  `run/3` is the ONLY entry point. It takes an explicit
  `Loopctl.ContextRetriever.Scope`, a `{entity, field, operation}` dispatch tuple
  (exactly the US-30.2 spec `metadata` shape), and the model-supplied params, and
  returns a page of allowlisted-only result maps. NO model-authored SQL ever
  reaches the database.

  ## Why an execute-time re-check (AC-30.3.1)

  Generate-time checks (US-30.2) bound the tool SURFACE, but a caller can craft a
  raw `/retrieve` dispatch tuple naming a field the entity does not declare, or one
  the entity declares but marks non-filterable. `run/3` therefore RE-VALIDATES the
  `(field, operation)` against BOTH the live entity definition (`entity.fields` +
  `filterable?`/searchable-text) AND the SERVER per-source column allowlist
  (`Entity.column_allowlist/0`, US-30.1 AC-30.1.2) before building any query. A
  request naming a field not currently allowlisted/filterable/searchable is
  REJECTED, never executed — this closes the raw-`/retrieve` bypass of
  generate-time checks. `run/3`'s job is to REJECT, not sanitize.

  ## Tenant scoping is dual (AC-30.3.2)

  Every query is scoped by BOTH mechanisms:

    * `Loopctl.Repo.with_tenant/2` sets the RLS context
      (`SET LOCAL app.current_tenant_id` + `SET LOCAL ROLE loopctl_app`), so RLS is
      actually enforced (the backing tables are RLS ENABLE, not FORCE); AND
    * an explicit `where: q.tenant_id == ^scope.tenant_id` predicate
      (defense-in-depth).

  The `tenant_id` is read ONLY from the scope, never from params — a `tenant_id`
  in the model-supplied params is ignored entirely (never cast, never read), so no
  param can widen or override the tenant.

  ## No model-authored SQL (AC-30.3.3)

  Field names map from the validated allowlist to KNOWN column atoms (via
  `Enum.find/2` matching `Atom.to_string/1` against the compile-time allowlist —
  never `String.to_atom/1` on model input). Filter values are cast to the declared
  field type and always Ecto-PINNED params (`^value`); the search query string is
  passed as a `websearch_to_tsquery` parameter. An injection payload in a filter
  value or search string is therefore a literal, matching nothing — not SQL.

  ## Indexed full-text search (AC-30.3.4)

  `:search` runs `search_vector @@ websearch_to_tsquery('english', ?)` against the
  GIN-indexed, trigger-maintained `tsvector` column added to each backing table by
  `20260712000000_add_search_vectors_to_backing_tables.exs` — NOT an on-the-fly
  `to_tsvector` sequential scan, and NOT `ILIKE`.

  Because that vector covers a FIXED per-source column set (stories: title +
  description; projects: name + description + mission; epics: title +
  description), a search is authorized ONLY when every declared searchable-text
  column is covered by the vector (`Entity.search_vector_columns/0`). A declared
  searchable column the vector does not index (e.g. `stories.agent_status`,
  `projects.slug` — allowlisted string-ish columns an admin may legitimately mark
  `searchable`) is REJECTED with `{:error, :search_not_indexed}` rather than
  silently searched against `title`/`description` (which would return wrong/empty
  results with no error). This is the execute-time half of the generate-time
  suppression in `ToolGenerator` (both enforce declared-searchable ⊆
  vector-covered). Note the vector may cover MORE columns than the entity
  declared searchable (e.g. an entity declaring only `title` still searches the
  `description` component of the shared vector); this residual is bounded because
  every vector column is itself server-allowlisted searchable text and results
  are shaped to declared columns only.

  ## Pagination + result shaping (AC-30.3.5)

  Every query is bounded by a hard maximum page size
  (`:context_retriever_max_page_size` config); a caller `limit` is clamped to
  `[1, max]`. Results select ONLY the entity's declared (allowlisted) columns into
  a map (`Ecto.Query.API.map/2` over resolved column atoms) — never `SELECT *`,
  never `metadata`/`tenant_id`/custody columns. The return carries
  `%{results, meta: %{total_count, limit, offset}}`.

  ## Audit (AC-30.3.6)

  Every executed query appends an `audit_log` entry
  (`entity_type: "context_retrieval"`) via the configured audit writer
  (`Loopctl.Audit.create_log_entry/2` by default), capturing tenant, actor,
  entity/field/operation, row count, and a SHA-256 digest of the params (raw
  param values are NOT stored — they may carry injection payloads / PII).

  The audit write is part of the read's correctness, NOT best-effort: AC-30.3.6
  mandates that EVERY execution appends an audit record, so if the audit insert
  fails `run/3` FAILS CLOSED with `{:error, :audit_failed}` and returns NO rows
  to the caller. A model-driven read over business data is therefore never
  disclosed without a persisted audit trail — the chain-of-custody guarantee
  outweighs returning an already-fetched page.

  ## Fail-closed edges (AC-30.3.7)

    * a `nil`-tenant (superadmin / no-impersonation) scope is refused with
      `{:error, :no_tenant}` — the executor NEVER touches `AdminRepo` for a
      cross-tenant read; and
    * a declared field whose backing column was renamed/dropped (a stale entity
      def) surfaces as `{:error, :stale_entity}` — the raw `Postgrex.Error` is
      caught and never propagated, so no schema internals are disclosed.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Audit
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.ContextRetriever.Scope
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Search.Regconfig
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  # backing_source atom -> Ecto schema module. The keys are exactly the phase-1
  # `Entity.backing_sources/0`; a source outside this map is treated as a stale
  # entity def (never a crash).
  @schemas %{stories: Story, projects: Project, epics: Epic}

  # Declared field types that are text-like (eligible to authorize the search
  # tool). Mirrors `ToolGenerator`'s `@text_types` (AC-30.2.1: "searchable TEXT
  # field", not merely "searchable field").
  @text_types ~w(string)

  @type dispatch :: {String.t(), String.t() | nil, :filter | :search}
  @type result :: %{
          results: [map()],
          meta: %{total_count: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}
        }
  @type error ::
          :no_tenant
          | :unknown_entity
          | :field_not_allowlisted
          | :invalid_operation
          | :search_not_indexed
          | :stale_entity
          | :audit_failed
          | :invalid_params
          | :unsupported_filter_type

  @doc """
  Executes a generated Context-Retriever tool call.

  ## Parameters

    * `scope` — a `Loopctl.ContextRetriever.Scope` carrying the `tenant_id`
      (isolation boundary) and audit actor. A `nil` `tenant_id` is refused.
    * `dispatch` — the `{entity_name, field, operation}` tuple from the US-30.2
      spec `metadata`. `entity_name` is a string, `field` a string for `:filter`
      (the field to match) or `nil` for `:search`, and `operation` is `:filter`
      or `:search`.
    * `params` — the model-supplied params map (string- or atom-keyed). For
      `:filter`, `params[field]` is the value to match; for `:search`,
      `params["query"]` is the search string. `params["limit"]`/`params["offset"]`
      drive pagination and are clamped. Any `tenant_id` here is IGNORED.

  ## Returns

    * `{:ok, %{results: [map()], meta: %{total_count, limit, offset}}}`
    * `{:error, atom()}` where atom is one of `:no_tenant`, `:unknown_entity`,
      `:field_not_allowlisted`, `:invalid_operation`, `:search_not_indexed`,
      `:stale_entity`, `:audit_failed`, `:invalid_params` (malformed call —
      non-`Scope` scope, non-tuple dispatch, or non-map params),
      `:unsupported_filter_type` (equality filter on a `:decimal` column, which
      only supports representation-fragile exact equality — rejected in v1).
  """
  @spec run(Scope.t(), dispatch(), map()) :: {:ok, result()} | {:error, error()}
  def run(scope, dispatch, params \\ %{})

  # AC-30.3.7a: a superadmin / no-impersonation context is refused BEFORE any DB
  # access — never a cross-tenant AdminRepo read.
  def run(%Scope{tenant_id: nil}, _dispatch, _params), do: {:error, :no_tenant}

  def run(%Scope{tenant_id: tenant_id} = scope, {entity_name, field, operation}, params)
      when is_binary(tenant_id) and is_map(params) do
    with {:ok, entity} <- resolve_entity(tenant_id, entity_name),
         {:ok, schema, allowlist} <- resolve_source(entity),
         select_cols = declared_columns(entity, allowlist),
         {:ok, plan} <- build_plan(operation, field, entity, allowlist, params),
         :ok <- reject_unsupported_filter(schema, plan) do
      limit = page_limit(params)
      offset = page_offset(params)

      case run_query(tenant_id, schema, select_cols, plan, limit, offset) do
        {:ok, total_count, rows} ->
          meta = %{total_count: total_count, limit: limit, offset: offset}
          finalize_read(scope, entity, operation, field, params, rows, meta)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Fail-closed catch-all: a malformed call — a non-`Scope` scope, a dispatch that
  # is not a `{entity, field, operation}` tuple, or `params` that is not a map
  # (e.g. a top-level JSON array body forwarded from US-30.4) — matches no clause
  # above and MUST return an error rather than raise `FunctionClauseError`. The
  # module is THE fail-closed security boundary; a crash on malformed input is
  # inconsistent with that contract.
  def run(_scope, _dispatch, _params), do: {:error, :invalid_params}

  # AC-30.3.6: the audit write is part of the read's correctness. If it fails we
  # FAIL CLOSED — no rows are returned without a persisted audit trail (chain of
  # custody outweighs the already-fetched page).
  defp finalize_read(scope, entity, operation, field, params, rows, meta) do
    case write_audit(scope, entity, operation, field, params, length(rows)) do
      :ok -> {:ok, %{results: rows, meta: meta}}
      {:error, _reason} -> {:error, :audit_failed}
    end
  end

  # --- Entity / source resolution ---

  defp resolve_entity(tenant_id, entity_name) when is_binary(entity_name) do
    case Registry.get_entity(tenant_id, entity_name) do
      %Entity{} = entity -> {:ok, entity}
      nil -> {:error, :unknown_entity}
    end
  end

  defp resolve_entity(_tenant_id, _entity_name), do: {:error, :unknown_entity}

  defp resolve_source(%Entity{backing_source: source}) do
    case {Map.get(@schemas, source), Map.get(Entity.column_allowlist(), source)} do
      {schema, allowlist} when not is_nil(schema) and is_list(allowlist) ->
        {:ok, schema, allowlist}

      _ ->
        # A backing_source with no schema/allowlist means the entity def no longer
        # matches the server's known sources — fail closed as stale.
        {:error, :stale_entity}
    end
  end

  # The declared, allowlisted columns to shape results to (AC-30.3.5). Each
  # declared field name is matched against the SERVER allowlist to a KNOWN column
  # atom (never String.to_atom); any declared field that no longer resolves is
  # dropped from the projection (defense-in-depth — the US-30.1 changeset already
  # guarantees membership).
  defp declared_columns(%Entity{fields: fields}, allowlist) do
    fields
    |> Enum.map(&Entity.field_string_value(&1, "name"))
    |> Enum.map(&column_atom(&1, allowlist))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # --- Plan building (allowlist re-check, AC-30.3.1) ---

  # A plan is `{:where, dynamic}` (filter/search where clause) or
  # `{:no_match, nil}` (a validly-typed request whose value can't match — e.g. a
  # non-numeric value for an integer column — which must return zero rows, never a
  # DB type error) plus an optional order clause. To keep the return small we
  # encode it as a map.
  defp build_plan(:filter, field, entity, allowlist, params) when is_binary(field) do
    with {:ok, field_element} <- declared_field(entity, field),
         true <- Entity.filterable?(field_element) || {:error, :field_not_allowlisted},
         col when not is_nil(col) <- column_atom(field, allowlist) do
      declared_type = Entity.field_string_value(field_element, "type")

      case cast_value(fetch_param(params, field), declared_type) do
        {:ok, value} ->
          {:ok, %{kind: :filter, column: col, value: value}}

        :no_match ->
          {:ok, %{kind: :no_match}}
      end
    else
      nil -> {:error, :field_not_allowlisted}
      {:error, reason} -> {:error, reason}
      false -> {:error, :field_not_allowlisted}
    end
  end

  defp build_plan(:search, _field, entity, allowlist, params) do
    case searchable_columns(entity, allowlist) do
      [] ->
        # No searchable TEXT field authorizes a search over this entity.
        {:error, :invalid_operation}

      cols ->
        if vector_covered?(entity, cols) do
          search_plan(fetch_param(params, "query"))
        else
          # AC-30.3.4: at least one declared searchable column is NOT covered by
          # the source's fixed `search_vector`, so it cannot be indexed in v1.
          # Reject rather than silently search the vector's (different) columns —
          # the execute-time half of ToolGenerator's generate-time suppression.
          {:error, :search_not_indexed}
        end
    end
  end

  # Unknown operation, or a :filter with a nil/non-string field.
  defp build_plan(_operation, _field, _entity, _allowlist, _params),
    do: {:error, :invalid_operation}

  # Reject a :filter whose backing column is `:decimal` (stories.estimated_hours).
  # The executor supports ONLY exact `field == ^value` equality, and an equality
  # between a stored NUMERIC and a bound param is representation-fragile — a
  # value that round-trips through the declared "float" cast (0.5 may match, 0.1
  # silently will not) — so a decimal-column filter would SILENTLY return
  # wrong/empty rows with no signal that equality-on-decimal is the wrong tool.
  # Fail explicitly instead. The `:decimal` verdict is read from the LIVE schema
  # (`__schema__/2`), so it can never drift from the column's real type. Only
  # :filter plans carry a column; :search / :no_match plans pass through.
  defp reject_unsupported_filter(schema, %{kind: :filter, column: col}) do
    case schema.__schema__(:type, col) do
      :decimal -> {:error, :unsupported_filter_type}
      _ -> :ok
    end
  end

  defp reject_unsupported_filter(_schema, _plan), do: :ok

  # A non-blank query is a real search; a blank/absent query matches nothing and
  # short-circuits to zero rows (websearch_to_tsquery('') would match nothing
  # anyway), never touching the DB.
  defp search_plan(query_string) when is_binary(query_string) do
    if String.trim(query_string) == "" do
      {:ok, %{kind: :no_match}}
    else
      {:ok, %{kind: :search, query_string: query_string}}
    end
  end

  defp search_plan(_query_string), do: {:ok, %{kind: :no_match}}

  # The declared field element for `field_name`, or nil (→ not allowlisted).
  defp declared_field(%Entity{fields: fields}, field_name) do
    case Enum.find(fields, fn f -> Entity.field_string_value(f, "name") == field_name end) do
      nil -> {:error, :field_not_allowlisted}
      field_element -> {:ok, field_element}
    end
  end

  # Declared fields that are both `searchable` and text-typed, mapped to their
  # server-allowlist column atoms (AC-30.3.1 search branch).
  defp searchable_columns(%Entity{fields: fields}, allowlist) do
    fields
    |> Enum.filter(fn f ->
      Entity.searchable?(f) and Entity.field_string_value(f, "type") in @text_types
    end)
    |> Enum.map(&Entity.field_string_value(&1, "name"))
    |> Enum.map(&column_atom(&1, allowlist))
    |> Enum.reject(&is_nil/1)
  end

  # Every declared searchable column must be covered by the source's generated
  # `search_vector` (`Entity.search_vector_columns/0`). Otherwise the fixed vector
  # query would search columns the entity never declared, or miss the declared one
  # entirely (AC-30.3.4). `cols` and the vector columns are both KNOWN atoms.
  defp vector_covered?(%Entity{backing_source: source}, cols) do
    vector_cols = Map.get(Entity.search_vector_columns(), source, [])
    Enum.all?(cols, &(&1 in vector_cols))
  end

  # Resolve a validated string field name to a KNOWN column atom from the SERVER
  # allowlist. Never String.to_atom/1 — matches Atom.to_string/1 of each
  # compile-time allowlist atom (US-30.1). Returns nil if not allowlisted.
  defp column_atom(nil, _allowlist), do: nil

  defp column_atom(name, allowlist) when is_binary(name) do
    Enum.find(allowlist, fn col -> Atom.to_string(col) == name end)
  end

  # --- Execution + audit ---

  # `:no_match` never touches the DB — a validly-shaped request that cannot match
  # any row (bad-typed filter value, blank search) returns an empty page and is
  # still audited (row_count 0).
  defp run_query(_tenant_id, _schema, _select_cols, %{kind: :no_match}, _limit, _offset) do
    {:ok, 0, []}
  end

  defp run_query(tenant_id, schema, select_cols, plan, limit, offset) do
    base = base_query(schema, tenant_id, plan)
    page_query = page_query(base, plan, select_cols, limit, offset)

    Repo.with_tenant(tenant_id, fn ->
      total = Repo.aggregate(base, :count, :id)
      rows = Repo.all(page_query)
      {total, rows}
    end)
    |> case do
      {:ok, {total, rows}} -> {:ok, total, rows}
      {:error, reason} -> {:error, translate_db_error(reason)}
    end
  rescue
    e in [Ecto.Query.CastError, Ecto.ChangeError] ->
      # AC-30.3.3 / AC-30.3.7b: the pinned filter value cannot be cast to the
      # column's REAL type. `cast_value/2` only casts to the entity's DECLARED
      # type, but an allowlisted `Ecto.Enum` column (stories.agent_status /
      # stories.verified_status / projects.status) or the `:decimal`
      # stories.estimated_hours has a real column type that DIVERGES from the only
      # declarable text type ("string"), so Ecto re-casts the pinned value at query
      # normalization and raises here — e.g. an injection payload `"' OR 1=1 --"`
      # or a stale/typo status `"ready"` against agent_status. Map it to :no_match
      # (zero rows, still audited) — EXACTLY the treatment `cast_value/2` gives a
      # bad-typed value — so injection-as-literal matches nothing (AC-30.3.3) and
      # `run/3` stays fail-closed (AC-30.3.7). The raw message is NEVER returned: it
      # echoes the payload AND discloses the column's enum member set / schema
      # internals, which AC-30.3.7b forbids.
      Logger.warning(
        "ContextRetriever.Executor un-castable pinned filter value " <>
          "(fail-closed as :no_match): #{inspect(e.__struct__)}"
      )

      {:ok, 0, []}

    e in Postgrex.Error ->
      # AC-30.3.7b: a dropped/renamed backing column (stale entity def) raises
      # `undefined_column`; any other DB error is likewise failed closed. The raw
      # error is logged server-side (rule 3) but NEVER returned — no schema
      # internals are disclosed to the caller.
      Logger.warning(
        "ContextRetriever.Executor DB error (fail-closed as :stale_entity): #{inspect(db_error_code(e))}"
      )

      {:error, :stale_entity}
  end

  # Where-only base query: RLS (via with_tenant) + explicit tenant predicate
  # (defense-in-depth) + the operation's dynamic where. Carries NO select so it
  # can back the count aggregate.
  defp base_query(schema, tenant_id, %{kind: :filter, column: col, value: value}) do
    from(q in schema,
      where: q.tenant_id == ^tenant_id,
      where: field(q, ^col) == ^value
    )
  end

  defp base_query(schema, tenant_id, %{kind: :search, query_string: query_string}) do
    # #492: match the deployment regconfig the CR backing-table triggers stored the
    # search_vector with; `?::text::regconfig` bind param (never interpolated). The `::text`
    # is required — a bare `?::regconfig` makes Postgrex demand the regconfig OID (integer)
    # and reject the string name at encode time.
    regconfig = Regconfig.get()

    from(q in schema,
      where: q.tenant_id == ^tenant_id,
      where:
        fragment(
          "search_vector @@ websearch_to_tsquery(?::text::regconfig, ?)",
          ^regconfig,
          ^query_string
        )
    )
  end

  # Whitelisted-map projection over ONLY the declared allowlisted columns
  # (AC-30.3.5) + deterministic ordering + pagination.
  defp page_query(base, %{kind: :search, query_string: query_string}, select_cols, limit, offset) do
    base
    |> order_by([q],
      desc:
        fragment("ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))", ^query_string),
      asc: q.id
    )
    |> select([q], map(q, ^select_cols))
    |> limit(^limit)
    |> offset(^offset)
  end

  defp page_query(base, _plan, select_cols, limit, offset) do
    base
    |> order_by([q], asc: q.id)
    |> select([q], map(q, ^select_cols))
    |> limit(^limit)
    |> offset(^offset)
  end

  defp write_audit(%Scope{} = scope, %Entity{} = entity, operation, field, params, row_count) do
    attrs = %{
      entity_type: "context_retrieval",
      entity_id: entity.id,
      action: to_string(operation),
      actor_type: "api_key",
      actor_id: scope.actor_id,
      actor_label: scope.actor_label,
      metadata: %{
        "entity" => entity.name,
        "backing_source" => to_string(entity.backing_source),
        "field" => field,
        "operation" => to_string(operation),
        "row_count" => row_count,
        "param_digest" => param_digest(params)
      }
    }

    # AC-30.3.6: the audit write is part of the read's correctness. On failure we
    # surface the error so `run/3` fails the read closed (returns no rows) rather
    # than disclosing business data with no persisted audit trail.
    case audit_writer().create_log_entry(scope.tenant_id, attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "ContextRetriever.Executor failed to write audit entry — failing read closed: " <>
            "#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Config-based DI for the audit writer (CLAUDE.md DI convention). Defaults to
  # `Loopctl.Audit`; `config/test.exs` maps it to a Mox mock so the fail-closed
  # path is exercisable without forcing a real audit-insert failure.
  defp audit_writer do
    Application.get_env(:loopctl, :context_retriever_audit, Audit)
  end

  # SHA-256 digest of the params — raw values are NEVER stored (they may carry
  # injection payloads / PII).
  defp param_digest(params) do
    :crypto.hash(:sha256, :erlang.term_to_binary(params)) |> Base.encode16()
  end

  # --- Param reading + value casting ---

  # Read a param under a string key, falling back to its EXISTING atom key (for
  # test ergonomics — API params arrive string-keyed). Never creates an atom.
  defp fetch_param(params, key) when is_binary(key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, existing_atom(key))
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp page_limit(params) do
    params
    |> fetch_param("limit")
    |> to_int(default_limit())
    |> max(1)
    |> min(max_page_size())
  end

  # Clamp the caller-supplied offset to `[0, max_offset]`. Bounding the UPPER end
  # matters: an uncapped offset (e.g. `offset: 100_000_000`) makes Postgres walk
  # and discard that many rows (O(offset)) before returning the capped page — a
  # residual unbounded-work vector on a surface governed as "no unindexed-scan
  # DoS", even though AC-30.3.5 only mandates a page-SIZE cap. The cap is
  # deliberately generous (deep paging still works) but finite.
  defp page_offset(params) do
    params
    |> fetch_param("offset")
    |> to_int(0)
    |> max(0)
    |> min(max_offset())
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  # Cast a filter param value to the declared field type. A nil value or a value
  # that cannot represent the declared type yields `:no_match` (the query returns
  # zero rows rather than a DB type error). The declared type comes from the
  # entity definition, never from model input.
  defp cast_value(nil, _type), do: :no_match

  defp cast_value(value, "integer"), do: cast_integer(value)
  defp cast_value(value, "float"), do: cast_float(value)
  defp cast_value(value, "boolean"), do: cast_boolean(value)
  defp cast_value(value, "datetime"), do: cast_datetime(value)

  # string / unknown declared type — compare as text.
  defp cast_value(value, _type) when is_binary(value), do: {:ok, value}
  defp cast_value(value, _type) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp cast_value(value, _type) when is_integer(value) or is_float(value),
    do: {:ok, to_string(value)}

  defp cast_value(_value, _type), do: :no_match

  defp cast_integer(value) when is_integer(value), do: {:ok, value}

  defp cast_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :no_match
    end
  end

  defp cast_integer(_value), do: :no_match

  defp cast_float(value) when is_float(value), do: {:ok, value}
  defp cast_float(value) when is_integer(value), do: {:ok, value * 1.0}

  defp cast_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> :no_match
    end
  end

  defp cast_float(_value), do: :no_match

  defp cast_boolean(value) when is_boolean(value), do: {:ok, value}
  defp cast_boolean("true"), do: {:ok, true}
  defp cast_boolean("false"), do: {:ok, false}
  defp cast_boolean(_value), do: :no_match

  defp cast_datetime(%DateTime{} = value), do: {:ok, value}

  defp cast_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :no_match
    end
  end

  defp cast_datetime(_value), do: :no_match

  # --- Config ---

  defp default_limit, do: min(20, max_page_size())

  defp max_page_size do
    Application.get_env(:loopctl, :context_retriever_max_page_size, 100)
  end

  # Hard upper bound on the pagination offset — bounds the O(offset) deep-scan a
  # model-driven call could otherwise trigger with an arbitrarily large offset.
  defp max_offset do
    Application.get_env(:loopctl, :context_retriever_max_offset, 100_000)
  end

  # --- DB error helpers ---

  defp translate_db_error(%Postgrex.Error{} = error) do
    Logger.warning(
      "ContextRetriever.Executor DB error (fail-closed as :stale_entity): #{inspect(db_error_code(error))}"
    )

    :stale_entity
  end

  # A non-Postgrex transaction failure (e.g. a rolled-back {:error, reason} from
  # the fun) is also failed closed rather than leaked.
  defp translate_db_error(_other), do: :stale_entity

  defp db_error_code(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp db_error_code(_), do: :unknown
end
