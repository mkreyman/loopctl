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
  @spec log_in_multi(Multi.t(), atom(), (map() -> map())) :: Multi.t()
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

  Entries are returned in ascending order by inserted_at, capped at `limit`.
  When more entries exist beyond the cap, `has_more` is true and `next_since`
  contains the `inserted_at` of the last returned entry.

  ## Options

  - `:project_id` — filter by project ID
  - `:entity_type` — filter by entity type
  - `:action` — filter by action
  - `:limit` — max entries to return (default from config, max 1000)

  ## Returns

  `{:ok, %{data: [%AuditLog{}], has_more: boolean, next_since: DateTime.t() | nil}}`
  """
  @spec list_changes(Ecto.UUID.t(), DateTime.t(), keyword()) ::
          {:ok, %{data: [AuditLog.t()], has_more: boolean(), next_since: DateTime.t() | nil}}
  def list_changes(tenant_id, since, opts \\ []) do
    default_limit = Application.get_env(:loopctl, :change_feed_limit, 1000)
    limit = opts |> Keyword.get(:limit, default_limit) |> max(1) |> min(1000)

    query =
      AuditLog
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.inserted_at > ^since)
      |> apply_filters(opts)
      |> order_by([a], asc: a.inserted_at)
      # Fetch one extra to determine has_more
      |> limit(^(limit + 1))

    results = AdminRepo.all(query)

    has_more = length(results) > limit
    entries = Enum.take(results, limit)

    next_since =
      if has_more do
        entries |> List.last() |> Map.get(:inserted_at)
      else
        nil
      end

    {:ok, %{data: entries, has_more: has_more, next_since: next_since}}
  end

  @doc """
  Returns audit log entries for a specific entity, ordered chronologically.

  Used by the story history shortcut endpoint and similar entity history views.

  Currently returns only direct audit entries for the given entity. It does
  not include entries for related entities (e.g., artifact_reports or
  verification_results referencing a story_id). Cross-entity history
  requires schemas from Epics 6-8.

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

    # NOTE(Epics 6-8): When artifact_reports and verification_results
    # schemas with story_id references are added, extend this query to
    # include related entity entries via UNION or OR-based entity_id matching.
    base_query =
      AuditLog
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.entity_type == ^entity_type and a.entity_id == ^entity_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    entries =
      base_query
      |> order_by([a], asc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: entries, total: total, page: page, page_size: page_size}}
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
