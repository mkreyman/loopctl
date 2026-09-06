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
  alias Loopctl.Knowledge.SearchEvent
  alias Loopctl.Projects
  alias Loopctl.Projects.Project
  alias Loopctl.WorkBreakdown.Stories

  # Must stay identical to `ArticleAccessEvent`'s `@access_types` — see the note there for why
  # `"drill"` exists and why the two allowlists move together (#569).
  @valid_access_types ~w(search get context index drill referenced)

  # A READ is a body actually delivered to an agent. `search` and `index` are IMPRESSIONS —
  # rows the RANKER produced, one per surfaced result — and they outnumber reads ~50:1 here.
  #
  # The distinction is enforced at ONE seam (`maybe_filter_access_type/2`, whose `nil` clause
  # means "reads", not "everything"), because the KB records the failure of assuming it at
  # each query surface instead: "the recording is transparent — each access row looks
  # identical whether from a direct get (user intent) or from a query result", so an aggregate
  # `COUNT(*) by article_id` ranks ranker output while reading as usage. Every surface that
  # exposes this data applies it, for the same reason a new exclusion has to be threaded
  # through per-article, per-project, per-agent, stats AND unused rather than only the primary
  # one — missing a single surface reintroduces the whole defect there. The three usage
  # builders construct their own `top_articles` query without the `:event` alias, so they
  # carry the predicate explicitly rather than through the seam.
  #
  # `drill` counts as a read: progressive disclosure delivers a body. It is deliberately
  # EXCLUDED from the heat index (`Knowledge.@heat_read_access_types`), and that divergence is
  # intended — heat asks "was this a deliberate vote", this asks "was a body delivered". Do
  # not unify the two lists.
  #
  # `referenced` is NOT a read and must never join this list. Every other type here is the
  # server observing a body it delivered; `referenced` is a CLIENT asserting that it used one
  # (`record_referenced/5`). Counting an assertion as a delivery would let a caller inflate
  # its own article's read counts, per-project and per-agent usage, and the "unused articles"
  # report — the same self-inflation `@heat_read_access_types` exists to prevent, one table
  # over.
  @read_access_types ~w(get context drill)

  # The access types that mean "a body was DELIVERED to the agent" — the ones worth
  # attributing back to a search. Deliberately the same three `RetrievalMetrics` counts as
  # follow-through, INCLUDING `drill`: #569 split drill out of the heat index so that index
  # could not rank on reads it caused itself, but "was this read produced by a search" is a
  # different question and a drill delivers a body like any other read.
  #
  # `referenced` is absent for a different reason from the impressions: its origin is not
  # RESOLVED at all. The caller names the recall, the server verifies the article was
  # surfaced under it, and `origin_search_id` is stamped from that verified id — so there is
  # nothing for `resolve_origins/5` to look up, and `origin_attribution` stays NULL because
  # its vocabulary (`same_key`/`cross_key`/`none`) describes how a lookup ESTABLISHED an
  # origin. Leaving it NULL is also what keeps `attributed_opens`/`direct_opens` counting
  # reads only.
  @attributable_access_types ~w(get context drill)

  # How far back a read looks for the search that surfaced it. Fixed at WRITE time, which is
  # the one thing that makes `origin_search_id` cheap and stable — but it means the
  # attributed counters do NOT move with `RetrievalMetrics`' query-time `window_seconds`.
  # Same default (30 min) so the two agree by construction on the common case; stated in the
  # metrics payload so nobody reads a divergence as a bug.
  @origin_window_seconds 1800

  @doc """
  The access types `record_access/6` will write.

  Exposed so the drift between this list and `ArticleAccessEvent.access_types/0` is
  ASSERTABLE. There is no DB CHECK on the column, so those two lists are the whole
  enforcement, and both directions of drift fail silently: a type missing here is
  dropped by `record_access/6`'s catch-all clause, and a type missing there fails
  `validate_inclusion` inside a fire-and-forget task nobody is watching.
  """
  @spec valid_access_types() :: [String.t()]
  def valid_access_types, do: @valid_access_types

  @doc """
  The access types that count as a READ (a body delivered), as opposed to an impression.

  Public so callers and tests can assert the set without reaching into the attribute.
  """
  @spec read_access_types() :: [String.t()]
  def read_access_types, do: @read_access_types

  @doc """
  Access-type values a CALLER may select on an analytics query.

  This is `valid_access_types/0` plus `"all"`, and the two lists are deliberately separate.
  `@valid_access_types` validates the access_type of a RECORDED event (`record_access/6`),
  so `"all"` must never appear there — it is a query selector, not a storable type, and
  admitting it would let a caller persist an event whose type means "every type".
  """
  @spec selectable_access_types() :: [String.t()]
  def selectable_access_types, do: ["all" | @valid_access_types]

  @doc """
  The access types whose rows get an `origin_search_id` resolved at write time.
  """
  @spec attributable_access_types() :: [String.t()]
  def attributable_access_types, do: @attributable_access_types

  @doc """
  The write-time lookback, in seconds, for resolving a read's originating search.

  Exposed because it is NOT the same knob as `RetrievalMetrics`' query-time
  `window_seconds`: this one is baked into each row when it is written and cannot be
  re-asked of history.
  """
  @spec origin_window_seconds() :: pos_integer()
  def origin_window_seconds, do: @origin_window_seconds

  # How many of a search's results get an `article_access_events` row (#582). Rows are
  # written per SURFACED RESULT, so an uncapped search would write an unbounded batch on
  # every call. The cap makes the recorded row count an UNDERCOUNT of the results a search
  # returned whenever a page exceeds it, which is why every batch also carries the true
  # `"results_returned"` figure.
  @max_recorded_search_results 20

  @doc """
  The cap on how many of a search's results are RECORDED as access events.

  Public so the ENFORCING call site (`Knowledge.maybe_record_search_access/5`) and every
  doc that publishes the cap (`RetrievalMetrics`, `RetrievalMetricSnapshot`, and the
  `GET /knowledge/analytics/retrieval-metrics` OpenAPI description) read ONE number and
  cannot drift — same discipline as `ArticleJSON.max_links_per_direction/0`.
  """
  @spec max_recorded_search_results() :: pos_integer()
  def max_recorded_search_results, do: @max_recorded_search_results

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
          optional(:story_id) => Ecto.UUID.t() | nil,
          # Set by the SEARCH SITE so the per-result rows share an id with the
          # one-per-attempt row in `search_events` (#658). It lives here, on the
          # internally-built context, rather than in the caller-supplied `metadata` map,
          # because a caller-controlled call-level denominator is one the caller can game
          # (#582). Kept in the closed type deliberately: widening this to `map()` would
          # let any future key through unchecked.
          optional(:search_id) => Ecto.UUID.t() | nil
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

  ONE ROW PER SURFACED RESULT, not one row per search call — this is the unit
  `RetrievalMetrics.compute/3` counts as `searched`, and mistaking it for a count of
  search CALLS is what produced #582. Two metadata keys make the distinction
  auditable downstream:

  - `"search_id"` — a UUID generated HERE, once per call, shared by every row in the
    batch. It is the only reliable search-call identity: the pre-#582 proxy
    (`api_key_id` + a shared `accessed_at`) collides across concurrent searches by one
    key. Never accept one from a caller — a call-level denominator a caller can forge
    is a metric a caller can game.
  - `"results_returned"` — how many results the search actually returned to its caller,
    which may exceed the number of rows written (callers cap what they record). Defaults
    to the batch size when the caller does not supply it.

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
      # The search_id is taken from the internally-built `context`, NEVER from the
      # caller-supplied `metadata` (#582): a call-level denominator the caller controls is a
      # metric the caller can game — pin every row to one id and `searches` collapses to 1.
      # #658 needs the per-RESULT rows to share the id with the one-per-ATTEMPT row in
      # `search_events`, so the SEARCH SITE passes it through `context`, which no API client
      # can reach. A metadata-supplied id is still discarded.
      |> Map.put("search_id", context_search_id(context) || Ecto.UUID.generate())
      |> Map.put_new("results_returned", length(article_ids))

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

  @doc """
  Records that a caller USED articles a recall surfaced — the third funnel stage.

  Surfaced → opened → REFERENCED. The first two are observations: the server wrote the
  surfacing rows and delivered the bodies. This one is an ASSERTION by the client, because
  nothing on the server can see which of the articles it handed over actually ended up in
  an answer. That is precisely the stage the KB has never been able to measure — measured
  surfaced-to-opened follow-through is 1.67%, and whether an opened article was USED was
  not recorded at all.

  Because it is an assertion, it is bounded rather than trusted:

    * `recall_id` is matched against `article_access_events` rows in the CALLER'S OWN
      tenant. There is no cross-tenant read and no existence oracle — an unknown id simply
      surfaces nothing, so every requested article comes back `not_surfaced`.
    * ONLY articles that recall actually surfaced under that `recall_id` are accepted. Any
      other id fails the whole call with `{:error, :not_surfaced, ids}`; nothing is written.
      This is all-or-nothing on purpose: a partial write would record a truth mixed with a
      rejection under one id and leave the caller unable to say which.
    * `api_key_id` is the CALLER'S key, stamped server-side, never taken from params.
    * `origin_search_id` is stamped from the VERIFIED `recall_id`, and `origin_attribution`
      stays NULL — see `@attributable_access_types` for why an asserted origin does not
      belong in that vocabulary.

  Writes SYNCHRONOUSLY, unlike every other recorder here, because the caller is told how
  many rows were recorded and a fire-and-forget count would be a guess.

  Repeat calls for the same `(recall_id, article_id)` write another row rather than
  erroring. `RetrievalMetrics` counts DISTINCT `(origin_search_id, article_id)` pairs, so a
  client that posts twice cannot inflate the metric; the duplicate rows are kept because
  `article_access_events` is an immutable event log, not a state table.

  ## Returns

    * `{:ok, %{recall_id: id, article_ids: [...], recorded: n}}`
    * `{:error, :not_surfaced, [ids]}` — the ids this recall did not surface
    * `{:error, :lookup_failed}` — the admission check itself could not run (logged). NOT
      folded into `not_surfaced`: that would blame the caller for a DB fault.
    * `{:error, :recording_failed}` — the insert itself failed (logged)
  """
  @spec record_referenced(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          Ecto.UUID.t(),
          context()
        ) ::
          {:ok, map()}
          | {:error, :not_surfaced, [String.t()]}
          | {:error, :lookup_failed | :recording_failed}
  def record_referenced(tenant_id, recall_id, article_ids, api_key_id, context \\ %{})

  def record_referenced(tenant_id, recall_id, article_ids, api_key_id, context)
      when is_binary(tenant_id) and is_binary(recall_id) and is_list(article_ids) and
             is_binary(api_key_id) do
    requested = article_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    with {:ok, ids} <- surfaced_article_ids(tenant_id, recall_id),
         surfaced = MapSet.new(ids),
         [] <- Enum.reject(requested, &MapSet.member?(surfaced, &1)) do
      insert_referenced(tenant_id, recall_id, requested, api_key_id, context)
    else
      {:error, :lookup_failed} -> {:error, :lookup_failed}
      missing when is_list(missing) -> {:error, :not_surfaced, missing}
    end
  end

  def record_referenced(_tenant_id, _recall_id, _article_ids, _api_key_id, _context),
    do: {:error, :recording_failed}

  @doc """
  The set of article ids a given recall/search SURFACED, within one tenant.

  The surfacing rows are the `access_type: "search"` rows carrying that id in
  `metadata->>'search_id'` — the id `search_combined/3` publishes as `meta.search_id` and
  the merged recall publishes as `meta.recall_id`. Public because it is the whole
  admission check for `record_referenced/5` and a test that cannot see it cannot pin it.

  Returns `{:ok, list}` — a plain LIST, not a `MapSet`, because a spec naming an opaque
  type a function builds itself is a dialyzer contract violation and the caller wraps it
  in a set anyway.

  A DB failure is `{:error, :lookup_failed}`, never an empty list. The recorders around
  here are fire-and-forget and rescue to a no-op, but this one is a caller-visible
  ADMISSION CHECK: an empty list means "this recall surfaced nothing", so folding a
  statement timeout into it would answer `422 not_surfaced` — a false statement about the
  caller's own ids — instead of a retryable fault.
  """
  @spec surfaced_article_ids(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [String.t()]} | {:error, :lookup_failed}
  def surfaced_article_ids(tenant_id, recall_id)
      when is_binary(tenant_id) and is_binary(recall_id) do
    ids =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.access_type == "search",
        where: fragment("?->>'search_id'", e.metadata) == ^recall_id,
        distinct: true,
        select: e.article_id
      )
      |> AdminRepo.all()

    {:ok, ids}
  rescue
    error ->
      Logger.warning("Knowledge.Analytics surfaced lookup failed: #{Exception.message(error)}")
      {:error, :lookup_failed}
  end

  def surfaced_article_ids(_tenant_id, _recall_id), do: {:ok, []}

  # The write half. Deliberately NOT `do_record_sync/5`: that path resolves the origin by
  # lookup, and `referenced` is not an attributable type there, so it would land every row
  # with a NULL `origin_search_id` — losing the only thing that ties the reference back to
  # the recall that produced it.
  defp insert_referenced(_tenant_id, recall_id, [], _api_key_id, _context),
    do: {:ok, %{recall_id: recall_id, article_ids: [], recorded: 0}}

  defp insert_referenced(tenant_id, recall_id, article_ids, api_key_id, context) do
    {project_id, story_id} = resolve_attribution(tenant_id, api_key_id, context)
    now = DateTime.utc_now()

    rows =
      Enum.map(article_ids, fn article_id ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          article_id: article_id,
          api_key_id: api_key_id,
          project_id: project_id,
          story_id: story_id,
          access_type: "referenced",
          metadata: %{"recall_id" => recall_id},
          accessed_at: now,
          # Stamped from the VERIFIED recall id — the article was proven surfaced under it
          # above. `origin_attribution` stays NULL: its three values describe how a
          # server-side LOOKUP established an origin, and this one was asserted and checked.
          origin_search_id: recall_id,
          origin_attribution: nil
        }
      end)

    {count, _} = AdminRepo.insert_all(ArticleAccessEvent, rows)
    {:ok, %{recall_id: recall_id, article_ids: article_ids, recorded: count}}
  rescue
    error ->
      # Unlike the fire-and-forget recorders, this one REPORTS the failure: the caller is
      # being told how many rows were written, and answering 200 for zero rows would be a
      # lie of exactly the kind rule 3 forbids.
      Logger.warning("Knowledge.Analytics referenced insert failed: #{Exception.message(error)}")

      {:error, :recording_failed}
  end

  # ---------------------------------------------------------------------------
  # Per-article stats
  # ---------------------------------------------------------------------------

  @doc """
  Returns aggregated access statistics for a single article.

  ## Returns

  A map with:

  - `:total_events` -- total event count, impressions included
  - `:total_reads` -- events that delivered a body (`get`/`context`/`drill`)
  - `:unique_keys` -- distinct `api_key_id` count. NOT an agent count: v2 mints one
    ephemeral key per dispatch, so one agent dispatched N times is N keys
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

    # `referenced` is a CLIENT ASSERTION, not an event the server observed, so it is
    # excluded from every counter an operator reads as delivery — `total_events` and
    # `unique_keys` included, or an agent could inflate both for its own article by
    # posting the same reference in a loop. It stays visible under its own label in
    # `accesses_by_type`, which is a breakdown rather than a total.
    observed = from(e in base, where: e.access_type != "referenced")

    total_events = AdminRepo.aggregate(observed, :count, :id)

    total_reads =
      from(e in base, where: e.access_type in @read_access_types)
      |> AdminRepo.aggregate(:count, :id)

    unique_keys =
      from(e in observed, select: count(e.api_key_id, :distinct))
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
      total_events: total_events,
      total_reads: total_reads,
      unique_keys: unique_keys,
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
  `%{article_id, title, category, access_count, unique_keys}`.

  `access_type` defaults to READS (`get`/`context`/`drill`), not to every event. Pass
  `access_type: "all"` for the old impressions-included behaviour, or a single type to
  select one. See `@read_access_types`.

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
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    since = Keyword.get(opts, :since) || default_since()
    access_type = Keyword.get(opts, :access_type)
    project_id = Keyword.get(opts, :project_id)
    group_by = Keyword.get(opts, :group_by, :article)

    case group_by do
      :project -> list_top_by_project(tenant_id, since, access_type, project_id, limit, offset)
      :agent -> list_top_by_agent(tenant_id, since, access_type, project_id, limit, offset)
      _ -> list_top_by_article(tenant_id, since, access_type, project_id, limit, offset)
    end
  end

  # Default grouping — per article. `offset` enables paging the ranking to
  # completeness (it is ranked by access count — a cheap btree aggregate, not a
  # vector scan — so deep offset is safe). A secondary `a.id` order keeps paging
  # stable across rows with equal counts.
  defp list_top_by_article(tenant_id, since, access_type, project_id, limit, offset) do
    # The join admits SYSTEM canonicals as well as this tenant's own articles, matching
    # `heat_counts_query`/`heat_article_ids` in `Loopctl.Knowledge`. A canonical has a NULL
    # `tenant_id`, so `a.tenant_id == ^tenant_id` silently dropped every read of one — the
    # EVENT rows were tenant-scoped and counted, the ARTICLE join then threw them away. Since
    # #572 made canonicals readable through `knowledge_get`, that meant heat_index ranked reads
    # this surface reported as never having happened, for the same tenant on the same corpus.
    # The `e.tenant_id == ^tenant_id` predicate below is what scopes the data; this join is
    # resolving a title, and it must not narrow the set a second time.
    query =
      from(e in ArticleAccessEvent,
        as: :event,
        join: a in Article,
        on: a.id == e.article_id and (a.tenant_id == ^tenant_id or a.scope == :system),
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^since,
        group_by: [a.id, a.title, a.category],
        order_by: [desc: count(e.id), asc: a.id],
        limit: ^limit,
        offset: ^offset,
        select: %{
          article_id: a.id,
          title: a.title,
          category: a.category,
          access_count: count(e.id),
          unique_keys: count(e.api_key_id, :distinct)
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
  defp list_top_by_project(tenant_id, since, access_type, project_id, limit, offset) do
    query =
      from(e in ArticleAccessEvent,
        as: :event,
        join: p in Project,
        on: p.id == e.project_id and p.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.accessed_at >= ^since,
        where: not is_nil(e.project_id),
        group_by: [p.id, p.name],
        order_by: [desc: count(e.id), asc: p.id],
        limit: ^limit,
        offset: ^offset,
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
  defp list_top_by_agent(tenant_id, since, access_type, project_id, limit, offset) do
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
    |> Enum.drop(offset)
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
  - `:api_key_count` -- number of *live* (non-revoked) keys currently
    belonging to the agent (when `resolved_as == :agent`)
  - `:total_reads` -- total events across ALL keys (live + revoked) for
    the agent. Revoked-key events still count toward historical totals.
  - `:unique_articles` -- distinct articles across ALL keys (live + revoked)
  - `:access_by_type` -- per-type counts across ALL keys (live + revoked)
  - `:top_articles` -- top articles read via *live* keys only. Revoked-key
    reads are excluded here so the list reflects the agent's current
    operational surface. This is the only field that uses the live-keys
    subset; every other aggregate includes revoked-key history.

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

    total_events = AdminRepo.aggregate(base, :count, :id)

    total_reads =
      from(e in base, where: e.access_type in @read_access_types)
      |> AdminRepo.aggregate(:count, :id)

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
        on: a.id == e.article_id and (a.tenant_id == ^tenant_id or a.scope == :system),
        where: e.tenant_id == ^tenant_id,
        where: e.api_key_id == ^api_key_id,
        where: e.accessed_at >= ^since,
        where: e.access_type in @read_access_types,
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
      total_events: total_events,
      total_reads: total_reads,
      unique_articles: unique_articles,
      access_by_type: access_by_type,
      top_articles: top_articles
    }
  end

  # Logical-agent rollup — aggregates every live api_key belonging to
  # the agent.
  #
  # Revoked-key handling follows AC-25.2.7: revoked-key events are
  # included in the "historical" aggregates (`total_reads`,
  # `unique_articles`, `access_by_type`) because the work happened and
  # still counts — but excluded from the "live breakdown" fields
  # (`api_key_count`, `top_articles`) which represent the agent's
  # current operational surface. This intentional split means
  # `sum(top_articles[:access_count])` can be less than `total_reads`
  # when the agent has revoked keys with historical reads.
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

    total_events = AdminRepo.aggregate(base, :count, :id)

    total_reads =
      from(e in base, where: e.access_type in @read_access_types)
      |> AdminRepo.aggregate(:count, :id)

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
        on: a.id == e.article_id and (a.tenant_id == ^tenant_id or a.scope == :system),
        where: e.tenant_id == ^tenant_id,
        where: e.api_key_id in subquery(live_keys),
        where: e.accessed_at >= ^since,
        where: e.access_type in @read_access_types,
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
      total_events: total_events,
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
  - `:since_days` -- window length in days (default 7, clamped to [1, 365]).
    Drives both the count window AND the `daily_series` length, so the
    two are always consistent.

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

    # `:since` is always derived from `:since_days` so the count window
    # and the `daily_series` length never desync. Callers cannot override
    # it directly.
    since = DateTime.add(DateTime.utc_now(), -since_days * 86_400, :second)

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

    total_events = AdminRepo.aggregate(base, :count, :id)

    total_reads =
      from(e in base, where: e.access_type in @read_access_types)
      |> AdminRepo.aggregate(:count, :id)

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
        on: a.id == e.article_id and (a.tenant_id == ^tenant_id or a.scope == :system),
        where: e.tenant_id == ^tenant_id,
        where: e.project_id == ^project.id,
        where: e.accessed_at >= ^since,
        where: e.access_type in @read_access_types,
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
      total_events: total_events,
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
  # `since_days` days. The day buckets are explicitly UTC calendar days
  # (not the Postgres session timezone) so the result matches
  # `Date.utc_today()` regardless of the DB server's `TimeZone` setting.
  # Ordered ascending (oldest first).
  defp build_daily_series(tenant_id, project_id, since_days) do
    today = Date.utc_today()
    start = Date.add(today, -(since_days - 1))

    # Group events by UTC calendar day. We cast `accessed_at AT TIME ZONE
    # 'UTC'` before `::date` so the bucket edges are always aligned with
    # `Date.utc_today()` even if the Postgres session TZ is not UTC.
    event_counts =
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id,
        where: e.project_id == ^project_id,
        where: fragment("((? AT TIME ZONE 'UTC'))::date", e.accessed_at) >= ^start,
        where: fragment("((? AT TIME ZONE 'UTC'))::date", e.accessed_at) <= ^today,
        group_by: fragment("((? AT TIME ZONE 'UTC'))::date", e.accessed_at),
        select: {fragment("((? AT TIME ZONE 'UTC'))::date", e.accessed_at), count(e.id)}
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

  # "Not accessed since the cutoff" is a correlated `not exists`, never
  # `a.id not in subquery(accessed_ids)` (#585). Same shape as the orphan check in
  # `Loopctl.Knowledge.find_orphan_articles/3` (#574), but for a different reason: this
  # one was HEALTHY in production, so the rewrite removes a cliff rather than a fire.
  #
  # PostgreSQL never converts `NOT IN (subquery)` into an anti-join — three-valued NULL
  # semantics forbid it, and it does not use a NOT NULL constraint to enable the
  # transformation (verified: `article_access_events.article_id` is NOT NULL and the
  # transformation still does not happen). What it does instead depends purely on SIZE.
  # If the subquery result fits `work_mem` it builds a hashed SubPlan (measured on prod:
  # work_mem 4 MB, 8,797 distinct accessed articles in the 30-day window, total plan cost
  # 2,663 — fine). If it does not fit, it silently degrades to Materialize plus one
  # re-scan per outer row, which is exactly what cost #574 2.21 BILLION. There is no
  # error and no warning at the crossover: the endpoint just goes from milliseconds to
  # unusable. Growth drivers here are articles read per window, the caller-supplied
  # `days_unused` (up to 365 via the controller), and raw event volume.
  #
  # A correlated `NOT EXISTS` is anti-join-able, so each candidate article becomes one
  # index probe on `article_access_events_tenant_article_time_idx`
  # (tenant_id, article_id, accessed_at) regardless of how large the accessed set gets.
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
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    cutoff = DateTime.add(DateTime.utc_now(), -days_unused * 86_400, :second)

    query =
      from(a in Article,
        as: :article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        where:
          not exists(
            from(e in ArticleAccessEvent,
              where: e.tenant_id == ^tenant_id,
              where: e.accessed_at >= ^cutoff,
              where: e.article_id == parent_as(:article).id,
              # READS only. On "any event at all", an article the ranker surfaces constantly
              # and nobody ever opens counted as USED — leaving the dead-weight detector
              # blind to the largest class of dead weight there is.
              where: e.access_type in @read_access_types,
              select: 1
            )
          ),
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: ^limit,
        offset: ^offset,
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

  @doc """
  Records ONE row per search ATTEMPT (#658), including the attempts that surface nothing.

  `record_search_access/6` writes one row per SURFACED RESULT and therefore cannot express
  a search that found nothing — it has no results to write a row about. That blindness is
  why 86 rejected calls and a silent embedding-timeout degradation had to be recovered by
  hand-mining 6,457 session transcripts. This is the counterpart that makes a miss a row.

  Fail-soft by construction: a telemetry write must never break a read. Errors are logged
  and swallowed.

  `attrs` is a map with any of the `SearchEvent` fields; `:outcome` is derived from
  `:degraded?` / `:rejected?` / `:result_count` when not supplied.
  """
  def record_search_attempt(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    query = Map.get(attrs, :query)

    row =
      attrs
      |> Map.drop([:degraded?, :rejected?])
      # `:degraded?` is the DERIVATION flag; `:degraded` is the COLUMN. Dropping the flag
      # without projecting it left the column permanently false, so the schema's own
      # `WHERE degraded` query returned nothing forever and every provider outage was
      # filed under `zero_results` — the misattribution the moduledoc exists to forbid.
      |> Map.put(:degraded, Map.get(attrs, :degraded?, false) == true)
      |> Map.put(:outcome, Map.get(attrs, :outcome) || SearchEvent.derive_outcome(attrs))
      |> Map.put(:query_terms, SearchEvent.term_count(query))

    case Application.get_env(:loopctl, :analytics_recording_mode, :async) do
      :sync ->
        insert_search_attempt(tenant_id, row)

      _async ->
        # BOUNDED fan-out, on its own supervisor. Each task takes one `AdminRepo` checkout
        # from a 3-connection BYPASSRLS pool shared with auth and the rate limiter, and the
        # highest-rate writer here is the REJECTION path — a misconfigured client in a retry
        # loop, i.e. exactly the incident this table exists to detect. An unbounded fan-out
        # would flood that pool precisely then. Over the cap `start_child` returns
        # `{:error, :max_children}` and the row is DROPPED (best-effort analytics, never
        # blocks a search), mirroring `Telemetry.IngestionWriteStatsTaskSupervisor`.
        Task.Supervisor.start_child(Loopctl.Knowledge.SearchEventTaskSupervisor, fn ->
          insert_search_attempt(tenant_id, row)
        end)

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Knowledge.Analytics search attempt spawn failed: #{Exception.message(error)}"
      )

      :ok
  end

  def record_search_attempt(_tenant_id, _attrs), do: :ok

  @doc false
  def insert_search_attempt(tenant_id, row) do
    %SearchEvent{tenant_id: tenant_id}
    |> SearchEvent.changeset(row)
    |> Loopctl.AdminRepo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("search_event insert rejected: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("search_event insert failed: #{Exception.message(error)}")
      :ok
  end

  # Reads a search_id the SEARCH SITE threaded through the internal attribution context.
  # Deliberately not reachable from the caller-supplied metadata map — see #582.
  defp context_search_id(context) when is_map(context) do
    case Map.get(context, :search_id) || Map.get(context, "search_id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp context_search_id(_), do: nil

  defp do_record_async([], _tenant_id, _api_key_id, _access_type, _context), do: :ok

  defp do_record_async(items, tenant_id, api_key_id, access_type, context) do
    # `context[:sync?]` (internal, set only by a server-side call site — never reachable
    # from a request body) forces the write onto the request path. The merged recall sets
    # it because it PUBLISHES the id these rows carry and a caller may hand it straight
    # back to `POST /recall/:recall_id/referenced`: off the request path the surfacing rows
    # have not committed yet, so an immediate reference reads an empty surfaced set and is
    # refused as `not_surfaced` with nothing written.
    case recording_mode(context) do
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

  defp recording_mode(context) do
    if Map.get(context, :sync?, false) do
      :sync
    else
      Application.get_env(:loopctl, :analytics_recording_mode, :async)
    end
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

    # ONE lookup for the whole batch, not one per item. A `context` call delivers up to a
    # page of articles, and a point query per row multiplied this path's `AdminRepo`
    # checkouts by the batch size — on a 3-connection BYPASSRLS pool (`ADMIN_POOL_SIZE`,
    # config/runtime.exs) that every authenticated request's rate-limit check also needs.
    origins =
      resolve_origins(tenant_id, Enum.map(items, &elem(&1, 0)), api_key_id, access_type, now)

    rows =
      Enum.map(items, fn {article_id, meta} ->
        {origin_search_id, origin_attribution} = origin_for(origins, article_id, access_type)

        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          article_id: article_id,
          api_key_id: api_key_id,
          project_id: project_id,
          story_id: story_id,
          access_type: access_type,
          metadata: ensure_map(meta),
          accessed_at: now,
          origin_search_id: origin_search_id,
          origin_attribution: origin_attribution
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
  # Origin attribution — which search surfaced the article this read opened
  # ---------------------------------------------------------------------------

  @doc false
  # Resolves `{origin_search_id, origin_attribution}` for a READ row, server-side.
  #
  # WHY THIS IS NOT A CALLER PARAMETER. `search_id` is already withheld from callers (#582)
  # because a call-level identity the caller controls is a metric the caller can game. An
  # `origin_search_id` a caller could assert is strictly worse: it would let one agent
  # manufacture follow-through for its own article, which is the heat-index failure
  # (#567/#569) reproduced one table over. The MCP server could technically thread it — it is
  # one process per session and knows what the last search returned — and that is exactly
  # what must not be built.
  #
  # WHY A LOOKUP AND NOT A JOIN AT READ TIME. `get`/`context`/`drill` rows carry no
  # `search_id`, so there is nothing to join ON; and the correlation that would substitute
  # for it binds `api_key_id`, which makes the injected recall hook — a different key from
  # the session that reads — structurally invisible. Resolving at write time fixes both and
  # costs one indexed lookup per RECORDED BATCH — `resolve_origins/5`, never one per row —
  # (`article_access_events_surface_lookup_idx`), on a path that is already async and
  # already best-effort.
  #
  # PREFERENCE ORDER, and why it is not "most recent wins": a surfacing by the READER'S OWN
  # key is direct evidence, so it is taken ahead of any other key's even when the other is
  # more recent. Only when no same-key surfacing exists does a cross-key one apply, and it is
  # labelled `cross_key` precisely because it is circumstantial — two agents in one tenant
  # can reach the same article independently.
  def resolve_origin(_tenant_id, article_id, _api_key_id, _access_type, _now)
      when not is_binary(article_id),
      do: {nil, nil}

  def resolve_origin(tenant_id, article_id, api_key_id, access_type, now) do
    case resolve_origins(tenant_id, [article_id], api_key_id, access_type, now) do
      origins when is_map(origins) -> origin_for(origins, article_id, access_type)
      _unresolvable -> {nil, nil}
    end
  end

  @doc false
  # The batch form: `%{article_id => {origin_search_id, origin_attribution}}` for the ids a
  # surfacing row was found for, `:unattributable` when the access type gets no attribution
  # at all, `:unavailable` when the lookup itself failed. An id absent from a returned map
  # was not surfaced in the window — `origin_for/3` decides what that means.
  def resolve_origins(_tenant_id, _article_ids, _api_key_id, access_type, _now)
      when access_type not in @attributable_access_types,
      do: :unattributable

  def resolve_origins(tenant_id, article_ids, api_key_id, _access_type, now)
      when is_binary(api_key_id) and is_list(article_ids) do
    since = DateTime.add(now, -@origin_window_seconds, :second)
    ids = article_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    query =
      from(s in ArticleAccessEvent,
        where: s.tenant_id == ^tenant_id,
        where: s.article_id in ^ids,
        where: s.access_type == "search",
        where: s.accessed_at >= ^since and s.accessed_at <= ^now,
        # One winner per article: same key first (direct evidence), then most recent.
        # `desc:` on the boolean puts true ahead of false.
        distinct: s.article_id,
        order_by: [
          asc: s.article_id,
          desc: fragment("? = ?", s.api_key_id, type(^api_key_id, Ecto.UUID)),
          desc: s.accessed_at
        ],
        select: {s.article_id, fragment("?->>'search_id'", s.metadata), s.api_key_id}
      )

    query
    |> AdminRepo.all()
    |> Map.new(fn
      # A surfacing row from before #582 carries no search_id. The article WAS surfaced,
      # so this is not `none` — but there is no id to point at, and inventing one would
      # put an unattributable read in the attributed bucket.
      {article_id, nil, _key} -> {article_id, {nil, nil}}
      {article_id, search_id, ^api_key_id} -> {article_id, {search_id, "same_key"}}
      {article_id, search_id, _other_key} -> {article_id, {search_id, "cross_key"}}
    end)
  rescue
    # Attribution is an enrichment, never a reason to lose the event. The caller's rescue in
    # `do_record_sync/5` would drop the whole row; this one degrades to an unattributed read.
    error ->
      Logger.warning("Knowledge.Analytics origin resolution failed: #{Exception.message(error)}")

      :unavailable
  end

  def resolve_origins(_tenant_id, _article_ids, _api_key_id, _access_type, _now), do: :unavailable

  defp origin_for(origins, article_id, access_type) when is_map(origins) do
    case Map.fetch(origins, article_id) do
      {:ok, resolved} -> resolved
      :error -> unsurfaced_origin(access_type)
    end
  end

  defp origin_for(_unresolvable, _article_id, _access_type), do: {nil, nil}

  # A read with no surfacing row is `none` — the agent went straight to the article — EXCEPT
  # for a drill. `progressive_index/3` runs its inner search with `_skip_record_access`, so
  # the index that surfaced the stub writes no row to find, and calling the documented way of
  # following an index a `direct_open` would populate that counter with its own opposite.
  # Unclassified (NULL) instead: it is in neither bucket until an index surfacing is
  # recorded.
  defp unsurfaced_origin("drill"), do: {nil, nil}
  defp unsurfaced_origin(_access_type), do: {nil, "none"}

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

  # Unspecified means READS, never "every row". The previous default mixed impressions into
  # every figure whose name promised reads, and impressions outnumber reads ~50:1, so the
  # default answer was ranker output wearing a usage label.
  defp maybe_filter_access_type(query, nil) do
    from([event: e] in query, where: e.access_type in @read_access_types)
  end

  # The explicit escape hatch for "I really do want impressions counted too".
  defp maybe_filter_access_type(query, "all"), do: query

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
