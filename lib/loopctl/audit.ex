defmodule Loopctl.Audit do
  @moduledoc """
  Context module for the immutable audit log.

  Provides functions to create and query audit log entries. This module
  is append-only — there are no update or delete operations.

  ## Usage

  ### Direct creation

      Loopctl.Audit.create_log_entry(tenant_id, %{
        entity_type: "project",
        entity_id: project.id,
        action: "created",
        actor_type: "api_key",
        actor_id: api_key.id,
        actor_label: "user:admin",
        new_state: %{name: "My Project"}
      })

  ### Inside an Ecto.Multi pipeline

      Multi.new()
      |> Multi.insert(:project, changeset)
      |> Loopctl.Audit.log_in_multi(:audit, fn changes ->
        %{
          tenant_id: tenant_id,
          entity_type: "project",
          entity_id: changes.project.id,
          action: "created",
          actor_type: "api_key",
          actor_id: api_key.id,
          actor_label: "user:admin",
          new_state: %{name: "My Project"}
        }
      end)
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.HeavyRead
  alias Loopctl.KeysetSeek

  @doc """
  Creates a new audit log entry within a tenant-scoped transaction.

  The `tenant_id` is set programmatically and must not be in the attrs cast.

  ## Parameters

  - `tenant_id` — the tenant UUID (or nil for superadmin actions)
  - `attrs` — map with entity_type, entity_id, action, actor_type, etc.

  ## Returns

  - `{:ok, %AuditLog{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_log_entry(Ecto.UUID.t() | nil, map()) ::
          {:ok, AuditLog.t()} | {:error, Ecto.Changeset.t()}
  def create_log_entry(tenant_id, attrs) do
    changeset =
      attrs
      |> AuditLog.create_changeset()
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)

    AdminRepo.insert(changeset)
  end

  @doc """
  Adds an audit log insert step to an Ecto.Multi pipeline.

  The `fun` receives the accumulated multi changes and must return
  a map of audit log attributes (including `tenant_id`).

  ## Parameters

  - `multi` — the Ecto.Multi struct
  - `name` — the step name in the multi (e.g., `:audit`)
  - `fun` — function that receives changes and returns attrs map

  ## Example

      Multi.new()
      |> Multi.update(:story, changeset)
      |> Audit.log_in_multi(:audit, fn %{story: story} ->
        %{
          tenant_id: story.tenant_id,
          entity_type: "story",
          entity_id: story.id,
          action: "updated",
          actor_type: "api_key",
          actor_id: api_key.id,
          actor_label: label,
          old_state: diff_old,
          new_state: diff_new
        }
      end)
  """
  @spec log_in_multi(Multi.t(), Multi.name(), (map() -> map())) :: Multi.t()
  def log_in_multi(%Multi{} = multi, name, fun) when is_function(fun, 1) do
    Multi.insert(multi, name, fn changes ->
      attrs = fun.(changes)
      tenant_id = Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id")
      attrs = Map.drop(attrs, [:tenant_id, "tenant_id"])

      attrs
      |> AuditLog.create_changeset()
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
    end)
  end

  @doc """
  Lists audit log entries for a tenant with optional filters and pagination.

  ## Options (keyword list)

  - `:entity_type` — filter by entity type
  - `:entity_id` — filter by entity ID
  - `:action` — filter by action
  - `:actor_type` — filter by actor type
  - `:actor_id` — filter by actor ID
  - `:project_id` — filter by project ID
  - `:from` — filter entries inserted at or after this DateTime
  - `:to` — filter entries inserted at or before this DateTime
  - `:page` — page number (default 1)
  - `:page_size` — entries per page (default 20, max 100)
  - `:order` — `:asc` or `:desc` (default `:desc`)

  ## Returns

  `{:ok, %{data: [%AuditLog{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_entries(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [AuditLog.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_entries(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    order = Keyword.get(opts, :order, :desc)
    offset = (page - 1) * page_size

    base_query =
      AuditLog
      |> where([a], a.tenant_id == ^tenant_id)
      |> apply_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    entries =
      base_query
      |> apply_order(order)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: entries, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns audit log entries for the change feed polling endpoint.

  US-27.9b: this is a KEYSET enumeration on the stable unique tuple
  `(inserted_at, id)`, ordered `inserted_at ASC, id ASC`, capped at `limit`. The
  `id` tie-break is mandatory — audit `inserted_at` is `utc_datetime_usec` and a
  bulk operation (an `Ecto.Multi` writing several entries) commits MULTIPLE rows at
  the SAME microsecond, so a timestamp-only `since` token either SKIPS the tied rows
  after a page boundary (silent gap) or RE-EMITS them (duplicate). Seeking on the
  tuple steps PAST a specific row regardless of timestamp ties.

  Two seek inputs (mutually exclusive in practice — the cursor wins when present):

  - `since` — a `DateTime` start position (`inserted_at > since`). Kept for
    back-compat with the original `?since=ISO8601` token, and used for the FIRST
    page (the caller has no cursor yet).
  - `:cursor` — the decoded `{inserted_at, id}` keyset position to seek AFTER
    (`(inserted_at, id) > (^c_inserted, ^c_id)`). Supplied on subsequent pages from
    the prior page's `next_cursor`. Drift-free across timestamp ties.

  When `:cursor` is present it takes precedence over `since`.

  ## Options

  - `:cursor` — decoded `{inserted_at, id}` keyset position (US-27.9b)
  - `:project_id` — filter by project ID
  - `:entity_type` — filter by entity type
  - `:action` — filter by action
  - `:limit` — max entries to return (default from config, max 1000)

  ## Returns

  `{:ok, %{data: [%AuditLog{}], has_more: boolean, next_since: DateTime.t() | nil,
    next_cursor: {DateTime.t(), Ecto.UUID.t()} | nil}}`

  `next_cursor` is the `(inserted_at, id)` of the last returned entry when more
  remain, else `nil` — the drift-free continuation token. `next_since` (the last
  entry's `inserted_at`) is retained for back-compat but is NOT tie-safe; new
  callers should follow `next_cursor`.
  """
  @spec list_changes(Ecto.UUID.t(), DateTime.t(), keyword()) ::
          {:ok,
           %{
             data: [AuditLog.t()],
             has_more: boolean(),
             next_since: DateTime.t() | nil,
             next_cursor: {DateTime.t(), Ecto.UUID.t()} | nil
           }}
  def list_changes(tenant_id, since, opts \\ []) do
    default_limit = Application.get_env(:loopctl, :change_feed_limit, 1000)
    limit = opts |> Keyword.get(:limit, default_limit) |> max(1) |> min(1000)

    # Fetch one extra to determine has_more (keyset peek, no COUNT — nothing to drift).
    query = changes_keyset_query(tenant_id, since, Keyword.put(opts, :limit, limit + 1))

    # US-27.9b: route through Loopctl.HeavyRead so the change-feed keyset read gets the
    # same dedicated-pool statement_timeout backstop (US-27.4) the index keyset path
    # uses, instead of a bare AdminRepo.all. The HeavyRead structural tenant guard
    # accepts the query because `changes_keyset_query/3` carries an explicit
    # `a.tenant_id == ^tenant_id` equality on the only base source. Opts come from the
    # single source of truth, `HeavyRead.opts/1` (shared with Knowledge — no drift).
    results = HeavyRead.all(tenant_id, query, HeavyRead.opts(:change_feed))

    has_more = length(results) > limit
    entries = Enum.take(results, limit)

    {next_since, next_cursor} =
      if has_more do
        last = List.last(entries)
        {last.inserted_at, {last.inserted_at, last.id}}
      else
        {nil, nil}
      end

    {:ok, %{data: entries, has_more: has_more, next_since: next_since, next_cursor: next_cursor}}
  end

  @doc """
  Builds the change-feed KEYSET seek QUERYABLE (US-27.9b), returned (not executed)
  so the `:scale_nightly` plan test can assert it is index-backed via `EXPLAIN`.

  This is the EXACT query `list_changes/3` runs (so the plan assertion guards the
  request path). `:limit` is applied as-is here (the caller adds the `+1` peek).

  Plan note (AC-27.9b.2): `audit_log` is RANGE-partitioned by month, so with
  `tenant_id =` plus the `(inserted_at, id)` row-value seek and
  `ORDER BY inserted_at ASC, id ASC`, the planner does PER-PARTITION Index Scans on the
  existing `(tenant_id, inserted_at)` btree, combined under either an **Append + a
  top-level Incremental Sort** (the empirical choice at 80k — each partition is
  presorted on `inserted_at`, the incremental sort finishes the `id` tie-break) or a
  **Merge Append** (cost-equivalent; the index lacks `id`). No Seq Scan, no Bitmap over
  the corpus — bounded by the keyset seek, cost ~O(page). The `:scale_nightly` plan test
  seeds across ≥2 monthly partitions and asserts both an ordered multi-partition scan and
  `refute_full_scan_audit` on the deep page.
  """
  @spec changes_keyset_query(Ecto.UUID.t(), DateTime.t(), keyword()) :: Ecto.Query.t()
  def changes_keyset_query(tenant_id, since, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 1000) |> max(1)

    AuditLog
    |> where([a], a.tenant_id == ^tenant_id)
    |> apply_changes_seek(since, Keyword.get(opts, :cursor))
    |> apply_filters(opts)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> limit(^limit)
  end

  # First page (no cursor): seek by the `since` timestamp (back-compat). Subsequent
  # pages: seek by the `(inserted_at, id)` keyset tuple, which steps PAST a specific
  # row regardless of how many share its timestamp (US-27.9b tie-safety). The cursor
  # takes precedence over `since` when both are present.
  defp apply_changes_seek(query, since, nil) do
    where(query, [a], a.inserted_at > ^since)
  end

  defp apply_changes_seek(query, _since, {%DateTime{}, id} = cursor) when is_binary(id) do
    # The `(inserted_at, id)` row-value seek, shared with the article/index/export
    # keysets via Loopctl.KeysetSeek (the load-bearing type/2 annotations live there).
    KeysetSeek.after_position(query, cursor)
  end

  @doc """
  Returns audit log entries for a specific entity, ordered chronologically.

  Used by the story history shortcut endpoint and similar entity history views.

  For `entity_type = "story"`, also includes token_usage_report audit entries
  where `metadata->>'story_id' = entity_id`, interleaved chronologically.
  This satisfies AC-21.8.6 (token usage events in story timeline).

  ## Options

  - `:page` — page number (default 1)
  - `:page_size` — entries per page (default 100, max 100)
  """
  @spec entity_history(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [AuditLog.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def entity_history(tenant_id, entity_type, entity_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 100) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query = build_entity_history_query(tenant_id, entity_type, entity_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    entries =
      base_query
      |> order_by([a], asc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: entries, total: total, page: page, page_size: page_size}}
  end

  # Builds the history query for an entity. For "story" entities, expands the
  # query to include related token_usage_report entries via metadata->>'story_id'.
  defp build_entity_history_query(tenant_id, "story", entity_id) do
    AuditLog
    |> where([a], a.tenant_id == ^tenant_id)
    |> where(
      [a],
      (a.entity_type == "story" and a.entity_id == ^entity_id) or
        (a.entity_type == "token_usage_report" and
           fragment("?->>'story_id' = ?", a.metadata, ^entity_id))
    )
  end

  defp build_entity_history_query(tenant_id, entity_type, entity_id) do
    AuditLog
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.entity_type == ^entity_type and a.entity_id == ^entity_id)
  end

  # --- Private filter helpers ---

  defp apply_filters(query, opts) do
    query
    |> filter_by(:entity_type, Keyword.get(opts, :entity_type))
    |> filter_by(:entity_id, Keyword.get(opts, :entity_id))
    |> filter_by(:action, Keyword.get(opts, :action))
    |> filter_by(:actor_type, Keyword.get(opts, :actor_type))
    |> filter_by(:actor_id, Keyword.get(opts, :actor_id))
    |> filter_by(:project_id, Keyword.get(opts, :project_id))
    |> filter_from(Keyword.get(opts, :from))
    |> filter_to(Keyword.get(opts, :to))
  end

  defp filter_by(query, _field, nil), do: query
  defp filter_by(query, _field, ""), do: query
  defp filter_by(query, :entity_type, val), do: where(query, [a], a.entity_type == ^val)
  defp filter_by(query, :entity_id, val), do: where(query, [a], a.entity_id == ^val)
  defp filter_by(query, :action, val), do: where(query, [a], a.action == ^val)
  defp filter_by(query, :actor_type, val), do: where(query, [a], a.actor_type == ^val)
  defp filter_by(query, :actor_id, val), do: where(query, [a], a.actor_id == ^val)
  defp filter_by(query, :project_id, val), do: where(query, [a], a.project_id == ^val)

  defp filter_from(query, nil), do: query
  defp filter_from(query, from), do: where(query, [a], a.inserted_at >= ^from)

  defp filter_to(query, nil), do: query
  defp filter_to(query, to), do: where(query, [a], a.inserted_at <= ^to)

  defp apply_order(query, :asc), do: order_by(query, [a], asc: a.inserted_at)
  defp apply_order(query, :desc), do: order_by(query, [a], desc: a.inserted_at)
end
