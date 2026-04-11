defmodule Loopctl.Knowledge.Analytics do
  @moduledoc """
  Analytics for the Knowledge Wiki.

  Provides article usage tracking via `record_access/6` and aggregate
  reporting functions consumed by the analytics endpoints.

  ## Recording access

  `record_access/6` and `record_search_access/6` are fire-and-forget:
  they spawn a `Task` that inserts the event row(s) and never raise
  back to the caller. This guarantees that read operations cannot fail
  because of analytics writes.

  ## Attribution context

  Recording functions accept an optional `context` map with the shape
  `%{project_id: uuid | nil, story_id: uuid | nil}`. When provided, the
  caller's project and/or story is persisted alongside the event for
  later attribution queries (US-25.1).

  Cross-tenant attribution attempts (e.g., tenant A passing tenant B's
  project_id) are silently dropped with a `:warning` log: the read
  itself always succeeds, but the attribution columns are set to NULL.

  When only `story_id` is provided, `project_id` is derived from the
  story's own `project_id` so the common orchestrator case ("I'm working
  on story X") never under-attributes.

  ## Tenant scoping

  All analytics queries are scoped by `tenant_id` and use `AdminRepo`
  (BYPASSRLS) following the same pattern as the rest of the
  `Loopctl.Knowledge` context.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Projects
  alias Loopctl.Projects.Project
  alias Loopctl.WorkBreakdown.Stories

  @valid_access_types ~w(search get context index)

  @typedoc """
  Optional metadata stored alongside the access event. Free-form map.
  Common keys: `"query"`, `"rank"`, `"score"`, `"mode"`.
  """
  @type metadata :: map()

  @typedoc """
  Optional attribution context for a recorded access event.

  `project_id` and/or `story_id` can be set to attribute the read to a
  specific unit of work. Both are validated against the caller's tenant
  before being persisted; cross-tenant values are silently dropped.
  """
  @type context :: %{
          optional(:project_id) => Ecto.UUID.t() | nil,
          optional(:story_id) => Ecto.UUID.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Recording
  # ---------------------------------------------------------------------------

  @doc """
  Fire-and-forget recording of a single article access.

  Spawns an unsupervised `Task` to insert the event row. Any error
  (including a missing article, missing api_key, or DB connectivity
  issues) is logged but never propagated to the caller.

  Returns `:ok` immediately.

  The optional `context` map attributes the event to a project and/or
  story. Cross-tenant values are silently dropped after a `:warning`
  log.
  """
  @spec record_access(
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          Ecto.UUID.t() | nil,
          String.t(),
          metadata(),
          context()
        ) :: :ok
  def record_access(
        tenant_id,
        article_id,
        api_key_id,
        access_type,
        metadata \\ %{},
        context \\ %{}
      )

  def record_access(_tenant_id, nil, _api_key_id, _access_type, _metadata, _context), do: :ok
  def record_access(_tenant_id, _article_id, nil, _access_type, _metadata, _context), do: :ok

  def record_access(tenant_id, article_id, api_key_id, access_type, metadata, context)
      when is_binary(article_id) and is_binary(api_key_id) and access_type in @valid_access_types do
    do_record_async([{article_id, metadata}], tenant_id, api_key_id, access_type, context)
    :ok
  end

  def record_access(_tenant_id, _article_id, _api_key_id, _access_type, _metadata, _context),
    do: :ok

  @doc """
  Fire-and-forget recording of search access for a list of article ids.

  Inserts one event per article id with `access_type: "search"` and
  the supplied query (and any extra metadata) attached. Each event also
  receives a `"rank"` key (1-based) reflecting the position in the
  results list.

  The optional `context` map attributes all rows in the batch to the
  same project and/or story. Cross-tenant values are silently dropped.
  """
  @spec record_search_access(
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          Ecto.UUID.t() | nil,
          String.t() | nil,
          metadata(),
          context()
        ) :: :ok
  def record_search_access(
        tenant_id,
        article_ids,
        api_key_id,
        query,
        metadata \\ %{},
        context \\ %{}
      )

  def record_search_access(_tenant_id, _ids, nil, _query, _metadata, _context), do: :ok
  def record_search_access(_tenant_id, [], _api_key_id, _query, _metadata, _context), do: :ok

  def record_search_access(tenant_id, article_ids, api_key_id, query, metadata, context)
      when is_list(article_ids) and is_binary(api_key_id) do
    base_meta =
      metadata
      |> ensure_map()
      |> maybe_put_query(query)

    items =
      article_ids
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {id, rank} when is_binary(id) -> [{id, Map.put(base_meta, "rank", rank)}]
        _ -> []
      end)

    do_record_async(items, tenant_id, api_key_id, "search", context)
    :ok
  end

  def record_search_access(_tenant_id, _ids, _api_key_id, _query, _metadata, _context), do: :ok

  @doc """
  Fire-and-forget recording of context access for a list of article ids.

  Inserts one event per article id with `access_type: "context"`.
  Each event also receives a 1-based `"rank"` reflecting position
  in the context result set.

  The optional `context` map attributes all rows in the batch to the
  same project and/or story. Cross-tenant values are silently dropped.
  """
  @spec record_context_access(
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          Ecto.UUID.t() | nil,
          metadata(),
          context()
        ) :: :ok
  def record_context_access(tenant_id, article_ids, api_key_id, metadata \\ %{}, context \\ %{})

  def record_context_access(_tenant_id, _ids, nil, _metadata, _context), do: :ok
  def record_context_access(_tenant_id, [], _api_key_id, _metadata, _context), do: :ok

  def record_context_access(tenant_id, article_ids, api_key_id, metadata, context)
      when is_list(article_ids) and is_binary(api_key_id) do
    base_meta = ensure_map(metadata)

    items =
      article_ids
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {id, rank} when is_binary(id) -> [{id, Map.put(base_meta, "rank", rank)}]
        _ -> []
      end)

    do_record_async(items, tenant_id, api_key_id, "context", context)
    :ok
  end

  def record_context_access(_tenant_id, _ids, _api_key_id, _metadata, _context), do: :ok

  # ---------------------------------------------------------------------------
  # Per-article stats
  # ---------------------------------------------------------------------------

  @doc """
  Returns aggregated access statistics for a single article.

  ## Returns

  A map with:

  - `:total_accesses` -- total event count
  - `:unique_agents` -- distinct `api_key_id` count
  - `:last_accessed_at` -- most recent `accessed_at` (or nil)
  - `:accesses_by_type` -- `%{"search" => N, "get" => N, ...}`
  - `:recent_accesses` -- last 10 events as plain maps
  """
  @spec get_article_stats(Ecto.UUID.t(), Ecto.UUID.t()) :: map()
  def get_article_stats(tenant_id, article_id) do
    base =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id and e.article_id == ^article_id
      )

    total = AdminRepo.aggregate(base, :count, :id)

    unique_agents =
      from(e in base, select: count(e.api_key_id, :distinct))
      |> AdminRepo.one()
      |> Kernel.||(0)

    last_accessed_at =
      from(e in base, select: max(e.accessed_at))
      |> AdminRepo.one()

    accesses_by_type =
      from(e in base, group_by: e.access_type, select: {e.access_type, count(e.id)})
      |> AdminRepo.all()
      |> Map.new()

    recent_accesses =
      from(e in base,
        order_by: [desc: e.accessed_at],
        limit: 10,
        select: %{
          id: e.id,
          api_key_id: e.api_key_id,
          access_type: e.access_type,
          metadata: e.metadata,
          accessed_at: e.accessed_at
        }
      )
      |> AdminRepo.all()

    %{
      article_id: article_id,
      total_accesses: total,
      unique_agents: unique_agents,
      last_accessed_at: last_accessed_at,
      accesses_by_type: accesses_by_type,
      recent_accesses: recent_accesses
    }
  end

  # ---------------------------------------------------------------------------
  # Top articles
  # ---------------------------------------------------------------------------

  @doc """
  Returns the top accessed articles for a tenant in a time window.

  ## Options

  - `:limit` -- max rows to return (default 20, max 100)
  - `:since` -- DateTime lower bound (default 7 days ago)
  - `:access_type` -- restrict to a single access type (optional)
  - `:project_id` -- filter events to this project_id only (optional)
  - `:group_by` -- `:article` (default), `:project`, or `:agent`

  When `group_by` is `:article`, each row is:
  `%{article_id, title, category, access_count, unique_agents}`.

  When `group_by` is `:project`, each row is:
  `%{project_id, project_name, access_count, unique_articles, unique_api_keys}`.

  When `group_by` is `:agent`, each row is:
  `%{agent_id, agent_name, agent_type, access_count, unique_articles, api_key_count}`.
  Events whose api_key has been revoked (or whose api_key row has been
  deleted) are aggregated into a synthetic `%{agent_id: nil,
  agent_name: "revoked", agent_type: nil, ...}` row.
  """
  @spec list_top_articles(Ecto.UUID.t(), keyword()) :: [map()]
  def list_top_articles(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    since = Keyword.get(opts, :since) || default_since()
    access_type = Keyword.get(opts, :access_type)
    project_id = Keyword.get(opts, :project_id)
    group_by = Keyword.get(opts, :group_by, :article)

    case group_by do
      :project -> list_top_by_project(tenant_id, since, access_type, project_id, limit)
      :agent -> list_top_by_agent(tenant_id, since, access_type, project_id, limit)
      _ -> list_top_by_article(tenant_id, since, access_type, project_id, limit)
    end
  end

  # Default grouping — per article.
  defp list_top_by_article(tenant_id, since, access_type, project_id, limit) do
    query =
      from(e in ArticleAccessEvent,
        as: :event,
        join: a in Article,
        on: a.id == e.article_id and a.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^since,
        group_by: [a.id, a.title, a.category],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          article_id: a.id,
          title: a.title,
          category: a.category,
          access_count: count(e.id),
          unique_agents: count(e.api_key_id, :distinct)
        }
      )

    query
    |> maybe_filter_access_type(access_type)
    |> maybe_filter_project(project_id)
    |> AdminRepo.all()
    |> Enum.map(fn row -> Map.update!(row, :category, &category_to_string/1) end)
  end

  # Group by project — only events with a non-NULL project_id contribute
  # (the filter explicitly excludes NULL-tagged events so rollup totals
  # stay tied to actual projects).
  defp list_top_by_project(tenant_id, since, access_type, project_id, limit) do
    query =
      from(e in ArticleAccessEvent,
        as: :event,
        join: p in Project,
        on: p.id == e.project_id and p.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^since,
        where: not is_nil(e.project_id),
        group_by: [p.id, p.name],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          project_id: p.id,
          project_name: p.name,
          access_count: count(e.id),
          unique_articles: count(e.article_id, :distinct),
          unique_api_keys: count(e.api_key_id, :distinct)
        }
      )

    query
    |> maybe_filter_access_type(access_type)
    |> maybe_filter_project(project_id)
    |> AdminRepo.all()
  end

  # Group by logical agent — INNER JOIN api_keys so we can read the
  # agent link, then LEFT JOIN agents so keys without a linked agent
  # still appear (bucketed under `agent_id: nil`, `agent_name: "unassigned"`).
  # Revoked keys are handled in a separate sentinel rollup below.
  defp list_top_by_agent(tenant_id, since, access_type, project_id, limit) do
    # Live keys — keys that exist AND are not revoked.
    live_query =
      from(e in ArticleAccessEvent,
        as: :event,
        join: k in ApiKey,
        on: k.id == e.api_key_id and k.tenant_id == ^tenant_id,
        left_join: ag in Agent,
        on: ag.id == k.agent_id and ag.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^since,
        where: is_nil(k.revoked_at),
        group_by: [k.agent_id, ag.name, ag.agent_type],
        select: %{
          agent_id: k.agent_id,
          agent_name: ag.name,
          agent_type: ag.agent_type,
          access_count: count(e.id),
          unique_articles: count(e.article_id, :distinct),
          api_key_count: count(k.id, :distinct)
        }
      )

    # Revoked / missing keys — collapsed under a single sentinel row.
    revoked_query =
      from(e in ArticleAccessEvent,
        as: :event,
        left_join: k in ApiKey,
        on: k.id == e.api_key_id and k.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^since,
        where: is_nil(k.id) or not is_nil(k.revoked_at),
        select: %{
          access_count: count(e.id),
          unique_articles: count(e.article_id, :distinct),
          api_key_count: count(e.api_key_id, :distinct)
        }
      )

    live_rows =
      live_query
      |> maybe_filter_access_type(access_type)
      |> maybe_filter_project(project_id)
      |> AdminRepo.all()
      |> Enum.map(&normalize_agent_row/1)

    revoked_row =
      revoked_query
      |> maybe_filter_access_type(access_type)
      |> maybe_filter_project(project_id)
      |> AdminRepo.one()
      |> build_revoked_row()

    (live_rows ++ List.wrap(revoked_row))
    |> Enum.sort_by(& &1.access_count, :desc)
    |> Enum.take(limit)
  end

  # Keys without a linked agent still belong to a caller — surface them
  # under a synthetic "unassigned" entry keyed by `k.agent_id = nil`.
  defp normalize_agent_row(%{agent_name: nil} = row) do
    row
    |> Map.put(:agent_name, "unassigned")
    |> Map.put(:agent_type, nil)
  end

  defp normalize_agent_row(%{agent_type: type} = row) when is_atom(type) and not is_nil(type) do
    Map.put(row, :agent_type, Atom.to_string(type))
  end

  defp normalize_agent_row(row), do: row

  defp build_revoked_row(%{access_count: 0}), do: nil
  defp build_revoked_row(nil), do: nil

  defp build_revoked_row(row) do
    %{
      agent_id: nil,
      agent_name: "revoked",
      agent_type: nil,
      access_count: row.access_count,
      unique_articles: row.unique_articles,
      api_key_count: row.api_key_count
    }
  end

  # ---------------------------------------------------------------------------
  # Per-agent usage
  # ---------------------------------------------------------------------------

  @doc """
  Returns usage statistics for a single agent identity.

  ## Dual-resolution

  The `id` parameter may be either an `api_keys.id` or an `agents.id`.

  1. The function first checks whether `id` matches an `api_key` row
     in the caller's tenant. If so, it returns the per-api-key rollup
     (`resolved_as: :api_key`).

  2. If not, it checks whether `id` matches an `agents.id` in the
     tenant. If so, it joins `api_keys` on `agent_id = id` and sums
     reads across every key belonging to that logical agent
     (`resolved_as: :agent`).

  3. If neither matches, returns `{:error, :not_found}`.

  ## Options

  - `:limit` -- max top articles to return (default 20, max 100)
  - `:since` -- DateTime lower bound (default 7 days ago)

  ## Returns

  `{:ok, usage_map}` where `usage_map` is a map with:

  - `:resolved_as` -- `:api_key` or `:agent`
  - `:api_key_id` -- the caller-supplied id (when `resolved_as == :api_key`)
  - `:agent_id` -- the logical agent id (when `resolved_as == :agent`)
  - `:agent_name` -- the agent's name (when `resolved_as == :agent`)
  - `:api_key_count` -- number of live keys rolled up (when `resolved_as == :agent`)
  - `:total_reads`
  - `:unique_articles`
  - `:access_by_type`
  - `:top_articles`

  …or `{:error, :not_found}` if neither an api_key nor an agent with the
  given id exists in the tenant.
  """
  @spec get_agent_usage(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def get_agent_usage(tenant_id, id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    since = Keyword.get(opts, :since) || default_since()

    with {:ok, cast_id} <- cast_uuid(id) do
      cond do
        api_key_exists?(tenant_id, cast_id) ->
          {:ok, build_api_key_usage(tenant_id, cast_id, since, limit)}

        agent_exists?(tenant_id, cast_id) ->
          {:ok, build_agent_usage(tenant_id, cast_id, since, limit)}

        true ->
          {:error, :not_found}
      end
    end
  end

  defp cast_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> {:error, :not_found}
    end
  end

  defp cast_uuid(_), do: {:error, :not_found}

  defp api_key_exists?(tenant_id, id) do
    AdminRepo.exists?(from k in ApiKey, where: k.id == ^id and k.tenant_id == ^tenant_id)
  end

  defp agent_exists?(tenant_id, id) do
    AdminRepo.exists?(from a in Agent, where: a.id == ^id and a.tenant_id == ^tenant_id)
  end

  # Per api_key rollup (original behavior).
  defp build_api_key_usage(tenant_id, api_key_id, since, limit) do
    base =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.api_key_id == ^api_key_id,
        where: e.accessed_at >= ^since
      )

    total_reads = AdminRepo.aggregate(base, :count, :id)

    unique_articles =
      from(e in base, select: count(e.article_id, :distinct))
      |> AdminRepo.one()
      |> Kernel.||(0)

    access_by_type =
      from(e in base, group_by: e.access_type, select: {e.access_type, count(e.id)})
      |> AdminRepo.all()
      |> Map.new()

    top_articles =
      from(e in ArticleAccessEvent,
        join: a in Article,
        on: a.id == e.article_id and a.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.api_key_id == ^api_key_id,
        where: e.accessed_at >= ^since,
        group_by: [a.id, a.title, a.category],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          article_id: a.id,
          title: a.title,
          category: a.category,
          access_count: count(e.id)
        }
      )
      |> AdminRepo.all()
      |> Enum.map(fn row -> Map.update!(row, :category, &category_to_string/1) end)

    %{
      resolved_as: :api_key,
      api_key_id: api_key_id,
      total_reads: total_reads,
      unique_articles: unique_articles,
      access_by_type: access_by_type,
      top_articles: top_articles
    }
  end

  # Logical-agent rollup — aggregates every live api_key belonging to
  # the agent. Revoked keys are excluded from the live count but still
  # contribute to `total_reads`.
  defp build_agent_usage(tenant_id, agent_id, since, limit) do
    agent = AdminRepo.get_by(Agent, id: agent_id, tenant_id: tenant_id)

    # Subquery: every api_key in this tenant belonging to the agent
    # (including revoked — their events still count toward total_reads).
    agent_keys =
      from(k in ApiKey,
        where: k.agent_id == ^agent_id and k.tenant_id == ^tenant_id,
        select: k.id
      )

    live_keys =
      from(k in ApiKey,
        where: k.agent_id == ^agent_id and k.tenant_id == ^tenant_id,
        where: is_nil(k.revoked_at),
        select: k.id
      )

    base =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.api_key_id in subquery(agent_keys),
        where: e.accessed_at >= ^since
      )

    total_reads = AdminRepo.aggregate(base, :count, :id)

    unique_articles =
      from(e in base, select: count(e.article_id, :distinct))
      |> AdminRepo.one()
      |> Kernel.||(0)

    access_by_type =
      from(e in base, group_by: e.access_type, select: {e.access_type, count(e.id)})
      |> AdminRepo.all()
      |> Map.new()

    api_key_count =
      from(k in ApiKey,
        where: k.agent_id == ^agent_id and k.tenant_id == ^tenant_id,
        where: is_nil(k.revoked_at)
      )
      |> AdminRepo.aggregate(:count, :id)

    top_articles =
      from(e in ArticleAccessEvent,
        join: a in Article,
        on: a.id == e.article_id and a.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.api_key_id in subquery(live_keys),
        where: e.accessed_at >= ^since,
        group_by: [a.id, a.title, a.category],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          article_id: a.id,
          title: a.title,
          category: a.category,
          access_count: count(e.id)
        }
      )
      |> AdminRepo.all()
      |> Enum.map(fn row -> Map.update!(row, :category, &category_to_string/1) end)

    %{
      resolved_as: :agent,
      agent_id: agent_id,
      agent_name: agent && agent.name,
      agent_type: agent && agent.agent_type && Atom.to_string(agent.agent_type),
      api_key_count: api_key_count,
      total_reads: total_reads,
      unique_articles: unique_articles,
      access_by_type: access_by_type,
      top_articles: top_articles
    }
  end

  # ---------------------------------------------------------------------------
  # Per-project usage
  # ---------------------------------------------------------------------------

  @doc """
  Returns a per-project rollup of wiki reads.

  The project must belong to the caller's tenant. Cross-tenant or
  missing projects return `{:error, :not_found}`.

  ## Options

  - `:limit` -- max top articles to return (default 20, max 100)
  - `:since` -- DateTime lower bound (default 7 days ago)
  - `:since_days` -- window length in days; overrides `:since` if given.
    Used to size the `daily_series`.

  ## Returns

  `{:ok, %{...}}` or `{:error, :not_found}`. The usage map has:

  - `:project_id`, `:project_name`
  - `:total_reads`, `:unique_articles`, `:unique_api_keys`, `:unique_agents`
  - `:access_by_type` -- `%{"search" => N, ...}`
  - `:top_articles` -- list with up to `limit` rows
  - `:daily_series` -- zero-filled array of `%{date: Date.t(), read_count: N}`
  """
  @spec get_project_usage(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def get_project_usage(tenant_id, project_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    since_days = opts |> Keyword.get(:since_days, 7) |> max(1) |> min(365)

    since =
      Keyword.get(opts, :since) || DateTime.add(DateTime.utc_now(), -since_days * 86_400, :second)

    with {:ok, cast_id} <- cast_uuid(project_id),
         {:ok, project} <- Projects.get_project(tenant_id, cast_id) do
      {:ok, build_project_usage(tenant_id, project, since, since_days, limit)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp build_project_usage(tenant_id, project, since, since_days, limit) do
    base =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.project_id == ^project.id,
        where: e.accessed_at >= ^since
      )

    total_reads = AdminRepo.aggregate(base, :count, :id)

    unique_articles =
      from(e in base, select: count(e.article_id, :distinct))
      |> AdminRepo.one()
      |> Kernel.||(0)

    unique_api_keys =
      from(e in base, select: count(e.api_key_id, :distinct))
      |> AdminRepo.one()
      |> Kernel.||(0)

    unique_agents =
      from(e in base,
        join: k in ApiKey,
        on: k.id == e.api_key_id and k.tenant_id == ^tenant_id,
        where: not is_nil(k.agent_id),
        select: count(k.agent_id, :distinct)
      )
      |> AdminRepo.one()
      |> Kernel.||(0)

    access_by_type =
      from(e in base, group_by: e.access_type, select: {e.access_type, count(e.id)})
      |> AdminRepo.all()
      |> Map.new()

    top_articles =
      from(e in ArticleAccessEvent,
        join: a in Article,
        on: a.id == e.article_id and a.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.project_id == ^project.id,
        where: e.accessed_at >= ^since,
        group_by: [a.id, a.title, a.category],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          article_id: a.id,
          title: a.title,
          category: a.category,
          access_count: count(e.id)
        }
      )
      |> AdminRepo.all()
      |> Enum.map(fn row -> Map.update!(row, :category, &category_to_string/1) end)

    daily_series = build_daily_series(tenant_id, project.id, since_days)

    %{
      project_id: project.id,
      project_name: project.name,
      total_reads: total_reads,
      unique_articles: unique_articles,
      unique_api_keys: unique_api_keys,
      unique_agents: unique_agents,
      access_by_type: access_by_type,
      top_articles: top_articles,
      daily_series: daily_series
    }
  end

  # Build a zero-filled daily read-count series for the last
  # `since_days` days. The day buckets are UTC days and the result is
  # ordered ascending (oldest first).
  defp build_daily_series(tenant_id, project_id, since_days) do
    today = Date.utc_today()
    start = Date.add(today, -(since_days - 1))

    # Group events by UTC calendar day.
    event_counts =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.project_id == ^project_id,
        where: fragment("(?)::date", e.accessed_at) >= ^start,
        where: fragment("(?)::date", e.accessed_at) <= ^today,
        group_by: fragment("(?)::date", e.accessed_at),
        select: {fragment("(?)::date", e.accessed_at), count(e.id)}
      )
      |> AdminRepo.all()
      |> Map.new()

    Enum.map(0..(since_days - 1), fn offset ->
      day = Date.add(start, offset)
      %{date: day, read_count: Map.get(event_counts, day, 0)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Unused articles
  # ---------------------------------------------------------------------------

  @doc """
  Returns published articles with zero accesses in the configured window.

  ## Options

  - `:days_unused` -- window length in days (default 30)
  - `:limit` -- max rows to return (default 50, max 200)
  """
  @spec list_unused_articles(Ecto.UUID.t(), keyword()) :: [map()]
  def list_unused_articles(tenant_id, opts \\ []) do
    days_unused = opts |> Keyword.get(:days_unused, 30) |> max(1)
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(200)
    cutoff = DateTime.add(DateTime.utc_now(), -days_unused * 86_400, :second)

    # Subquery: article ids that HAVE been accessed since the cutoff
    accessed_ids =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^cutoff,
        distinct: true,
        select: e.article_id
      )

    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        where: a.id not in subquery(accessed_ids),
        order_by: [asc: a.inserted_at],
        limit: ^limit,
        select: %{
          article_id: a.id,
          title: a.title,
          category: a.category,
          tags: a.tags,
          inserted_at: a.inserted_at,
          updated_at: a.updated_at
        }
      )

    query
    |> AdminRepo.all()
    |> Enum.map(fn row -> Map.update!(row, :category, &category_to_string/1) end)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_record_async([], _tenant_id, _api_key_id, _access_type, _context), do: :ok

  defp do_record_async(items, tenant_id, api_key_id, access_type, context) do
    case Application.get_env(:loopctl, :analytics_recording_mode, :async) do
      :sync ->
        do_record_sync(items, tenant_id, api_key_id, access_type, context)

      _async ->
        Task.Supervisor.start_child(
          Loopctl.TaskSupervisor,
          fn -> do_record_sync(items, tenant_id, api_key_id, access_type, context) end
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Knowledge.Analytics async record failed to spawn: #{Exception.message(error)}"
      )

      :ok
  end

  @doc false
  # Synchronous insertion path used by both the async task and tests.
  #
  # Attribution (`project_id` / `story_id`) is validated here, inside the
  # async task, so validation failures never reach the caller's code path.
  # Cross-tenant values are silently dropped with a :warning log that
  # includes the caller's `api_key_id` so operators can trace which agent
  # is sending bad attribution.
  def do_record_sync(items, tenant_id, api_key_id, access_type, context \\ %{}) do
    {project_id, story_id} = resolve_attribution(tenant_id, api_key_id, context)
    now = DateTime.utc_now()

    rows =
      Enum.map(items, fn {article_id, meta} ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          article_id: article_id,
          api_key_id: api_key_id,
          project_id: project_id,
          story_id: story_id,
          access_type: access_type,
          metadata: ensure_map(meta),
          accessed_at: now
        }
      end)

    case AdminRepo.insert_all(ArticleAccessEvent, rows) do
      {_count, _} ->
        :ok
    end
  rescue
    error ->
      # Broad rescue so analytics failures never propagate to the read
      # caller. Logged at :warning so operators can see dropped events in
      # production; callers still see :ok. Malformed UUIDs in the
      # attribution context are caught earlier in validate_project/2 and
      # validate_story/2 and never reach this rescue.
      Logger.warning(
        "Knowledge.Analytics record failed (event dropped): " <>
          Exception.message(error)
      )

      :ok
  end

  # ---------------------------------------------------------------------------
  # Attribution resolution
  # ---------------------------------------------------------------------------

  # Resolves `project_id` and `story_id` from the context map after
  # validating cross-tenant access. Returns `{project_id, story_id}` where
  # either may be `nil` when the caller did not supply it or when the
  # supplied id belonged to another tenant.
  #
  # `api_key_id` is threaded through only so warning logs can identify
  # the caller when attribution is dropped (it is never used for
  # authorization here — that already happened upstream).
  #
  # When only `story_id` is provided and it validates, `project_id` is
  # derived from the story's own `project_id`.
  defp resolve_attribution(tenant_id, api_key_id, context) do
    context = ensure_map(context)
    raw_project_id = Map.get(context, :project_id) || Map.get(context, "project_id")
    raw_story_id = Map.get(context, :story_id) || Map.get(context, "story_id")

    validated_story = validate_story(tenant_id, api_key_id, raw_story_id)
    validated_project = resolve_project(tenant_id, api_key_id, raw_project_id, validated_story)

    {unwrap_project(validated_project), unwrap_story(validated_story)}
  end

  # Resolves the project attribution. When the caller supplied an explicit
  # `project_id`, validate it. Otherwise, derive it from the validated story
  # (the common orchestrator case — "I'm working on story X").
  defp resolve_project(tenant_id, api_key_id, raw_project_id, _validated_story)
       when not is_nil(raw_project_id) do
    validate_project(tenant_id, api_key_id, raw_project_id)
  end

  defp resolve_project(_tenant_id, _api_key_id, _raw_project_id, {:ok, %{project_id: derived}}) do
    {:ok, derived}
  end

  defp resolve_project(_tenant_id, _api_key_id, _raw_project_id, _validated_story), do: {:ok, nil}

  defp unwrap_project({:ok, id}), do: id
  defp unwrap_project(:drop), do: nil

  defp unwrap_story({:ok, %{id: id}}), do: id
  defp unwrap_story(_), do: nil

  # Validates a project_id against the caller's tenant.
  #
  # Returns:
  #
  # - `{:ok, nil}` when no id was provided
  # - `{:ok, uuid}` when the id belongs to the tenant
  # - `:drop` when the id is malformed, cross-tenant, or non-binary (logs a warning)
  #
  # Malformed (non-UUID) binaries are rejected by `Ecto.UUID.cast/1` before
  # the DB query so the underlying `get_project/2` never raises
  # `Ecto.Query.CastError`. This is critical because the enclosing
  # `do_record_sync/5` uses a broad rescue that would otherwise swallow the
  # entire event row insertion.
  #
  # `api_key_id` is included in the warning log so operators can trace
  # which caller is sending bad attribution.
  defp validate_project(_tenant_id, _api_key_id, nil), do: {:ok, nil}

  defp validate_project(tenant_id, api_key_id, project_id) when is_binary(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, cast_id} ->
        case Projects.get_project(tenant_id, cast_id) do
          {:ok, _project} ->
            {:ok, cast_id}

          {:error, :not_found} ->
            Logger.warning(
              "cross-tenant project_id dropped" <>
                " tenant_id=#{tenant_id}" <>
                " api_key_id=#{inspect(api_key_id)}" <>
                " project_id=#{cast_id}"
            )

            :drop
        end

      :error ->
        Logger.warning(
          "invalid project_id dropped" <>
            " tenant_id=#{tenant_id}" <>
            " api_key_id=#{inspect(api_key_id)}" <>
            " project_id=#{inspect(project_id)}"
        )

        :drop
    end
  end

  defp validate_project(tenant_id, api_key_id, project_id) do
    Logger.warning(
      "invalid project_id dropped" <>
        " tenant_id=#{tenant_id}" <>
        " api_key_id=#{inspect(api_key_id)}" <>
        " project_id=#{inspect(project_id)}"
    )

    :drop
  end

  # Validates a story_id against the caller's tenant.
  #
  # Returns:
  #
  # - `{:ok, nil}` when no id was provided
  # - `{:ok, %{id: uuid, project_id: uuid | nil}}` on success
  # - `:drop` when cross-tenant, malformed, or non-binary (logs a warning)
  #
  # Same malformed-UUID guarding as `validate_project/3` — `Ecto.UUID.cast/1`
  # shields `Stories.get_story/2` from `Ecto.Query.CastError`.
  #
  # `api_key_id` is included in the warning log so operators can trace
  # which caller is sending bad attribution.
  defp validate_story(_tenant_id, _api_key_id, nil), do: {:ok, nil}

  defp validate_story(tenant_id, api_key_id, story_id) when is_binary(story_id) do
    case Ecto.UUID.cast(story_id) do
      {:ok, cast_id} ->
        case Stories.get_story(tenant_id, cast_id) do
          {:ok, story} ->
            {:ok, %{id: story.id, project_id: story.project_id}}

          {:error, :not_found} ->
            Logger.warning(
              "cross-tenant story_id dropped" <>
                " tenant_id=#{tenant_id}" <>
                " api_key_id=#{inspect(api_key_id)}" <>
                " story_id=#{cast_id}"
            )

            :drop
        end

      :error ->
        Logger.warning(
          "invalid story_id dropped" <>
            " tenant_id=#{tenant_id}" <>
            " api_key_id=#{inspect(api_key_id)}" <>
            " story_id=#{inspect(story_id)}"
        )

        :drop
    end
  end

  defp validate_story(tenant_id, api_key_id, story_id) do
    Logger.warning(
      "invalid story_id dropped" <>
        " tenant_id=#{tenant_id}" <>
        " api_key_id=#{inspect(api_key_id)}" <>
        " story_id=#{inspect(story_id)}"
    )

    :drop
  end

  defp default_since do
    DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp maybe_put_query(map, nil), do: map
  defp maybe_put_query(map, ""), do: map
  defp maybe_put_query(map, query) when is_binary(query), do: Map.put(map, "query", query)
  defp maybe_put_query(map, _), do: map

  defp maybe_filter_access_type(query, nil), do: query

  defp maybe_filter_access_type(query, type) when type in @valid_access_types do
    from([event: e] in query, where: e.access_type == ^type)
  end

  defp maybe_filter_access_type(query, _), do: query

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project_id) when is_binary(project_id) do
    from([event: e] in query, where: e.project_id == ^project_id)
  end

  defp maybe_filter_project(query, _), do: query

  defp category_to_string(nil), do: nil
  defp category_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp category_to_string(other), do: to_string(other)
end
