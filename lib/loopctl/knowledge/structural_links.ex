defmodule Loopctl.Knowledge.StructuralLinks do
  @moduledoc """
  Harvests `derived_from` edges from provenance the corpus already carries (US-42.1, #611
  stage 0.5).

  ## Why this exists

  Measured on the hosted corpus for #611: every one of ~1.4M `relates_to` edges is a cosine
  threshold artifact — zero structural, zero hand-made — with 59% sitting in the 0.60-0.70
  band just above the floor, and `precision@20 = 0.038`. The issue's own diagnosis is that
  the graph "has exactly one dimension, sliced into thirds and given three names". Stage 0
  (`Loopctl.Knowledge.LinkPruning`) bounded that graph's density, but pruning a
  single-dimensional graph leaves it single-dimensional.

  `ArticleLink` has always declared a `derived_from` type that NOTHING produced: it is read
  by the OKF exporter and written by no code path. Meanwhile articles extracted from one
  source share a source-family tag. This module is the missing producer, and the edges it
  writes are the first class in the corpus that is TRUE rather than probable.

  ## A star, never a clique

  The obvious harvest — link every article to its siblings — is catastrophic at this
  corpus's shape. Measured 2026-08-20 via `knowledge_facets(tag_prefix: "book-")`: 210
  distinct book sources, the largest contributing 1,523 articles. Sibling-to-sibling over
  that ONE book is ~1.16M edges, more than the entire pre-pruning graph stage 0 was filed
  to reduce.

  Routing siblings through one hub costs N edges instead of N²/2, keeps two-hop
  reachability meaningful, and produces a node with a NAME an agent can read — which
  sibling-to-sibling edges never do.

  ## Where the source signal actually lives

  The `source_type` / `source_id` COLUMNS are largely unpopulated: `knowledge_get` on a
  book-extracted article (tagged `book-9baec82a16b7`) returns `null` for both. The real
  signal is the source-family TAG (`book-`, `doc-`, `repo-`, `yt-`), so resolution is
  tag-first with the columns as a fallback. A column-first harvest would have found almost
  nothing. Per the recorded finding on #137, `source_id` is deliberately NOT per-article
  unique — a shared source across siblings is the signal this module consumes, not a defect.

  ## Repo topology (the decision AC-42.1.7 left open, settled against `tenancy-rls`)

  * The SCAN is a heavy enumeration over the whole corpus, so it goes through
    `Loopctl.HeavyRead` — never `AdminRepo`, whose 3-connection pool is load-bearing for
    every authenticated request. `HeavyRead`'s `guard!/2` additionally RAISES unless every
    base-table source carries a conjunctive `tenant_id` predicate bound to the passed
    tenant, which is what makes the isolation structural rather than a promise.
  * A heavy read can be SHED. `scan/2` asks for `on_overload: :tag` and the caller
    propagates `{:error, :heavy_read_overloaded}` — binding a shed result as a list would
    crash exactly under the load the gate exists for.
  * The WRITES are bounded (one hub plus N edges per qualifying source) and follow the
    other system link-writers onto `AdminRepo`. RLS does nothing there, so the explicit
    `tenant_id` is the only isolation and it is set programmatically, never cast.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink

  require Logger

  @source_tag_prefixes ~w(book- doc- repo- yt-)

  @default_min_siblings 3

  @doc """
  Harvests source hubs and their `derived_from` star edges for one tenant.

  Idempotent: a second run over an unchanged corpus creates no hub and no edge. Hubs are
  resolved by a deterministic `idempotency_key`, and edges rely on the composite unique
  index on `(tenant_id, source_article_id, target_article_id, relationship_type)`.

  Returns `{:ok, report}` or `{:error, :heavy_read_overloaded}`.
  """
  @spec harvest(binary(), keyword()) ::
          {:ok, map()} | {:error, :heavy_read_overloaded}
  def harvest(tenant_id, opts \\ []) when is_binary(tenant_id) do
    floor = Keyword.get(opts, :min_siblings, min_siblings())

    case scan(tenant_id, opts) do
      {:error, :heavy_read_overloaded} = shed ->
        shed

      articles ->
        {qualifying, skipped} =
          articles
          |> group_by_source()
          |> Enum.split_with(fn {_source, members} -> length(members) >= floor end)

        report =
          Enum.reduce(qualifying, blank_report(skipped, articles, floor), fn {source, members},
                                                                             acc ->
            harvest_one_source(tenant_id, source, members, acc)
          end)

        log_report(tenant_id, report)
        {:ok, report}
    end
  end

  # ------------------------------------------------------------------
  # Scan
  # ------------------------------------------------------------------

  defp scan(tenant_id, opts) do
    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        where: is_nil(a.metadata["hub_kind"]),
        select: %{id: a.id, tags: a.tags, source_type: a.source_type, source_id: a.source_id}
      )

    HeavyRead.all(tenant_id, query, Keyword.merge([on_overload: :tag], opts))
  end

  # ------------------------------------------------------------------
  # Source resolution — tag first, columns as the fallback
  # ------------------------------------------------------------------

  @doc """
  Resolves an article's source key, or `nil` when it carries none.

  Public so the resolution rule can be unit-tested directly rather than only through a
  whole harvest — the tag-vs-column precedence is the part measurement corrected, and it
  is worth pinning on its own.
  """
  @spec source_key(map()) :: String.t() | nil
  def source_key(%{} = article) do
    case source_tag(article[:tags] || []) do
      nil -> column_source(article)
      tag -> tag
    end
  end

  defp source_tag(tags) when is_list(tags) do
    Enum.find(tags, fn tag ->
      is_binary(tag) and Enum.any?(@source_tag_prefixes, &String.starts_with?(tag, &1))
    end)
  end

  defp source_tag(_tags), do: nil

  defp column_source(%{source_type: type, source_id: id})
       when is_binary(type) and is_binary(id),
       do: "#{type}-#{id}"

  defp column_source(_article), do: nil

  defp group_by_source(articles) do
    articles
    |> Enum.reduce(%{}, fn article, acc ->
      case source_key(article) do
        nil -> acc
        key -> Map.update(acc, key, [article], &[article | &1])
      end
    end)
    |> Enum.sort_by(fn {key, _members} -> key end)
  end

  # ------------------------------------------------------------------
  # Hub + edges
  # ------------------------------------------------------------------

  defp harvest_one_source(tenant_id, source, members, acc) do
    case resolve_or_create_hub(tenant_id, source) do
      {:ok, hub, :created} ->
        write_edges(tenant_id, hub, members, %{acc | hubs_created: acc.hubs_created + 1})

      {:ok, hub, :resolved} ->
        write_edges(tenant_id, hub, members, %{acc | hubs_resolved: acc.hubs_resolved + 1})

      {:ok, hub, :adopted} ->
        write_edges(tenant_id, hub, members, %{acc | hubs_adopted: acc.hubs_adopted + 1})

      {:error, reason} ->
        Logger.warning("structural_links: hub failed for #{source}: #{inspect(reason)}")
        %{acc | hub_failures: acc.hub_failures + 1}
    end
  end

  # Three steps, in this order, and the middle one is the point.
  #
  # Most sources ALREADY HAVE A HUB. Every extraction skill produces one — `book-`,
  # `doc-`, `yt-` and `repo-` captures each emit "hub + atomic notes" — and that hub
  # carries the source's REAL name ("Advanced Cypher Concepts", not
  # "book-6a3020c2cd15"). Minting our own beside it would put a digest-named rival next
  # to a well-named article that is already there, and doing that weekly across every
  # tenant would quietly double the hub population. So: adopt what exists, mint only
  # where nothing does.
  #
  # Adoption keys off the `hub` TAG, and tags are agent-writable via knowledge_update —
  # which is exactly why `KnowledgeMocWorker` keys its own hubs off an idempotency_key
  # instead. The weaker signal is acceptable HERE and not there: the choice is only ever
  # between articles inside one tenant's own source group, the effect is which sibling
  # becomes the centre of a navigational star, and nothing is destroyed either way.
  # Selection is oldest-first so a re-run is stable rather than racing ties.
  defp resolve_or_create_hub(tenant_id, source) do
    key = hub_idempotency_key(source)

    cond do
      hub = minted_hub(tenant_id, key) -> {:ok, hub, :resolved}
      hub = existing_source_hub(tenant_id, source) -> {:ok, hub, :adopted}
      true -> create_hub(tenant_id, source, key)
    end
  end

  defp minted_hub(tenant_id, key) do
    AdminRepo.one(
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.idempotency_key == ^key,
        select: a
      )
    )
  end

  defp existing_source_hub(tenant_id, source) do
    AdminRepo.one(
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        where: ^source in a.tags,
        where: "hub" in a.tags,
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: 1,
        select: a
      )
    )
  end

  defp create_hub(tenant_id, source, key) do
    attrs = %{
      title: "Source: #{hub_title(source)}",
      # Never invent a source's human name. A hub named by its digest is still a
      # navigational win over no hub; a hub named by a hallucinated book title is worse
      # than nothing, because it reads as a fact.
      body: hub_body(source),
      category: "reference",
      # PUBLISHED explicitly. `create_article/3` defaults to :draft (the "publishes by
      # default" behaviour belongs to the proposal path, not this one), and a draft hub is
      # invisible to search, the index and the heat candidate set — which makes it not
      # navigation at all, defeating the entire point of the star. Caught by mutation
      # testing: the heat-exclusion guard passed vacuously because the hub was never a
      # heat candidate in the first place.
      status: :published,
      tags: [source, "hub", "source-hub"],
      idempotency_key: key,
      metadata: %{"hub_kind" => "source", "source_key" => source}
    }

    # The novelty gate lives in `propose_article/3`, NOT here: `create_article/3` is the
    # direct, ungated path. That matters for this writer rather than being trivia — hubs
    # are structurally near-identical to one another by construction, so a gated create
    # would stage every one after the first as a draft and the harvest would silently
    # produce unpublished hubs. Using the ungated path is the deliberate choice; do not
    # "improve" this by routing it through propose_article.
    case Knowledge.create_article(tenant_id, attrs) do
      {:ok, %Article{} = hub} ->
        {:ok, hub, :created}

      # A title collision means a hub for this source already exists under a different
      # idempotency_key — treat it as resolved, never as a failure, so a re-run converges
      # instead of logging the same error every night.
      {:error, :duplicate_title, %Article{} = hub} ->
        {:ok, hub, :resolved}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp write_edges(tenant_id, hub, members, acc) do
    # ArticleLink.inserted_at is :utc_datetime_usec — truncating to :second makes Ecto
    # raise on dump. It also has no updated_at (links are immutable), so only one stamp.
    now = DateTime.utc_now()

    rows =
      members
      |> Enum.reject(&(&1.id == hub.id))
      |> Enum.map(
        &%{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          source_article_id: &1.id,
          target_article_id: hub.id,
          relationship_type: :derived_from,
          metadata: %{"origin" => "structural_links"},
          inserted_at: now
        }
      )

    {inserted, _} =
      AdminRepo.insert_all(ArticleLink, rows,
        on_conflict: :nothing,
        conflict_target: [
          :tenant_id,
          :source_article_id,
          :target_article_id,
          :relationship_type
        ]
      )

    %{acc | edges_created: acc.edges_created + inserted}
  end

  # ------------------------------------------------------------------
  # Naming, config, reporting
  # ------------------------------------------------------------------

  defp hub_idempotency_key(source), do: "structural-hub-" <> source

  # The tag IS the name we have. Strip the family prefix for readability and leave the
  # digest — see the comment in create_hub/3 about never inventing a title.
  defp hub_title(source) do
    Enum.reduce(@source_tag_prefixes, source, fn prefix, acc ->
      String.replace_prefix(acc, prefix, String.trim_trailing(prefix, "-") <> " ")
    end)
  end

  defp hub_body(source) do
    """
    Navigational hub for everything extracted from the source `#{source}`.

    Every article derived from this source carries a `derived_from` edge to this node, so
    its siblings are one hop away. Created mechanically by
    `Loopctl.Knowledge.StructuralLinks` from provenance the corpus already carried — this
    node asserts co-origin, which is exact, and asserts nothing about similarity.
    """
  end

  defp min_siblings do
    Application.get_env(:loopctl, :structural_hub_min_siblings, @default_min_siblings)
  end

  defp blank_report(skipped, articles, floor) do
    %{
      hubs_created: 0,
      hubs_resolved: 0,
      hubs_adopted: 0,
      hub_failures: 0,
      edges_created: 0,
      sources_below_floor: length(skipped),
      articles_without_source: Enum.count(articles, &is_nil(source_key(&1))),
      min_siblings: floor
    }
  end

  # A run that creates nothing says so, rather than exiting silently (AC-42.1.9): "no new
  # edges" and "the sweep never ran" are the two readings that must not look alike.
  defp log_report(tenant_id, report) do
    Logger.info(
      "structural_links: tenant=#{tenant_id} hubs_created=#{report.hubs_created} " <>
        "hubs_adopted=#{report.hubs_adopted} " <>
        "hubs_resolved=#{report.hubs_resolved} edges_created=#{report.edges_created} " <>
        "sources_below_floor=#{report.sources_below_floor} " <>
        "articles_without_source=#{report.articles_without_source} " <>
        "hub_failures=#{report.hub_failures}"
    )
  end
end
