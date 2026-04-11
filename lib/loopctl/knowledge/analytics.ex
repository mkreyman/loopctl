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
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Projects
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

  Each row is a map with `:article_id`, `:title`, `:category`,
  `:access_count`, and `:unique_agents`.
  """
  @spec list_top_articles(Ecto.UUID.t(), keyword()) :: [map()]
  def list_top_articles(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    since = Keyword.get(opts, :since) || default_since()
    access_type = Keyword.get(opts, :access_type)

    query =
      from(e in ArticleAccessEvent,
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
    |> AdminRepo.all()
    |> Enum.map(fn row -> Map.update!(row, :category, &category_to_string/1) end)
  end

  # ---------------------------------------------------------------------------
  # Per-agent usage
  # ---------------------------------------------------------------------------

  @doc """
  Returns usage statistics for a single api_key (agent identity).

  ## Options

  - `:limit` -- max top articles to return (default 20, max 100)
  - `:since` -- DateTime lower bound (default 7 days ago)

  ## Returns

  A map with:

  - `:api_key_id`
  - `:total_reads` -- total events for this agent
  - `:unique_articles` -- distinct articles read
  - `:access_by_type` -- `%{"search" => N, ...}`
  - `:top_articles` -- top N read articles with counts
  """
  @spec get_agent_usage(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: map()
  def get_agent_usage(tenant_id, api_key_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    since = Keyword.get(opts, :since) || default_since()

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
      api_key_id: api_key_id,
      total_reads: total_reads,
      unique_articles: unique_articles,
      access_by_type: access_by_type,
      top_articles: top_articles
    }
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
  # Cross-tenant values are silently dropped with a :warning log.
  def do_record_sync(items, tenant_id, api_key_id, access_type, context \\ %{}) do
    {project_id, story_id} = resolve_attribution(tenant_id, context)
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
      Logger.debug(
        "Knowledge.Analytics record failed (silently ignored): " <>
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
  # When only `story_id` is provided and it validates, `project_id` is
  # derived from the story's own `project_id`.
  defp resolve_attribution(tenant_id, context) do
    context = ensure_map(context)
    raw_project_id = Map.get(context, :project_id) || Map.get(context, "project_id")
    raw_story_id = Map.get(context, :story_id) || Map.get(context, "story_id")

    validated_story = validate_story(tenant_id, raw_story_id)
    validated_project = resolve_project(tenant_id, raw_project_id, validated_story)

    {unwrap_project(validated_project), unwrap_story(validated_story)}
  end

  # Resolves the project attribution. When the caller supplied an explicit
  # `project_id`, validate it. Otherwise, derive it from the validated story
  # (the common orchestrator case — "I'm working on story X").
  defp resolve_project(tenant_id, raw_project_id, _validated_story)
       when not is_nil(raw_project_id) do
    validate_project(tenant_id, raw_project_id)
  end

  defp resolve_project(_tenant_id, _raw_project_id, {:ok, %{project_id: derived}}) do
    {:ok, derived}
  end

  defp resolve_project(_tenant_id, _raw_project_id, _validated_story), do: {:ok, nil}

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
  # - `:drop` when the id is cross-tenant or malformed (logs a warning)
  defp validate_project(_tenant_id, nil), do: {:ok, nil}

  defp validate_project(tenant_id, project_id) when is_binary(project_id) do
    case Projects.get_project(tenant_id, project_id) do
      {:ok, _project} ->
        {:ok, project_id}

      {:error, :not_found} ->
        Logger.warning(
          "cross-tenant project_id dropped tenant_id=#{tenant_id} project_id=#{project_id}"
        )

        :drop
    end
  end

  defp validate_project(tenant_id, project_id) do
    Logger.warning(
      "invalid project_id dropped tenant_id=#{tenant_id} project_id=#{inspect(project_id)}"
    )

    :drop
  end

  # Validates a story_id against the caller's tenant.
  #
  # Returns:
  #
  # - `{:ok, nil}` when no id was provided
  # - `{:ok, %{id: uuid, project_id: uuid | nil}}` on success
  # - `:drop` when cross-tenant or malformed (logs a warning)
  defp validate_story(_tenant_id, nil), do: {:ok, nil}

  defp validate_story(tenant_id, story_id) when is_binary(story_id) do
    case Stories.get_story(tenant_id, story_id) do
      {:ok, story} ->
        {:ok, %{id: story.id, project_id: story.project_id}}

      {:error, :not_found} ->
        Logger.warning(
          "cross-tenant story_id dropped tenant_id=#{tenant_id} story_id=#{story_id}"
        )

        :drop
    end
  end

  defp validate_story(tenant_id, story_id) do
    Logger.warning(
      "invalid story_id dropped tenant_id=#{tenant_id} story_id=#{inspect(story_id)}"
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
    from([e, _a] in query, where: e.access_type == ^type)
  end

  defp maybe_filter_access_type(query, _), do: query

  defp category_to_string(nil), do: nil
  defp category_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp category_to_string(other), do: to_string(other)
end
