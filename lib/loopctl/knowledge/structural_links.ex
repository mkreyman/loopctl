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
  * The scan is KEYSET-BATCHED and reduces each page to `source => [id]` before reading
    the next. Loading the whole corpus at once OOM-killed the production BEAM on the first
    real run; the `tags` array was the weight, not the row count. See `collect_sources/2`.
  * A heavy read can be SHED. Each page asks for `on_overload: :tag` and the caller
    propagates `{:error, :heavy_read_overloaded}` — binding a shed result as a list would
    crash exactly under the load the gate exists for, and a partially-grouped corpus is
    not a usable answer anyway.
  * The WRITES are bounded (one hub plus N edges per qualifying source) and follow the
    other system link-writers onto `AdminRepo`. RLS does nothing there, so the explicit
    `tenant_id` is the only isolation and it is set programmatically, never cast.
  """

  @behaviour Loopctl.Knowledge.StructuralLinksBehaviour

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink

  require Logger

  @source_tag_prefixes ~w(book- doc- repo- yt-)

  @default_min_siblings 3

  # These writes are made by a scheduled worker holding no key, so they are attributed to
  # the SYSTEM actor. `Knowledge` otherwise defaults `actor_type` to "api_key" with a nil
  # id, which records every unattended hub mint and retitle against an API key that does
  # not exist — in a product whose premise is attributable custody. Same shape as
  # `KnowledgeMocWorker`.
  @actor [actor_type: "system", actor_label: "worker:structural_links"]

  # A tag must cover at least this fraction of a source's members to name its hub. High on
  # purpose: the point is to abstain rather than to guess (see hub_title/3).
  @hub_name_coverage 0.9

  # Format and structure tags: true of the source but not a NAME for it.
  @hub_name_stoplist ~w(book books document documents reference hub moc source-hub actionable
                        pdf epub md txt html code external youtube video article audible
                        administrator admin user users owner author guest unknown untitled
                        none default temp draft copy final new old misc other
                        microsoft-word word excel powerpoint scan scanned export)

  # Keyset page size for the corpus scan. Bounds PEAK MEMORY, not total work — every
  # article is still visited, just never all at once. See collect_sources/2.
  @scan_batch 2000

  # Rows per `insert_all`. ArticleLink writes 7 fields, so Postgres's 65,535-parameter
  # wire ceiling is reached at 9,363 rows — see write_edges/4.
  @edge_insert_chunk 2000

  @doc """
  Harvests source hubs and their `derived_from` star edges for one tenant.

  Idempotent: a second run over an unchanged corpus creates no hub and no edge. Hubs are
  resolved by a deterministic `idempotency_key`, and edges rely on the composite unique
  index on `(tenant_id, source_article_id, target_article_id, relationship_type)`.

  Returns `{:ok, report}` or `{:error, :heavy_read_overloaded}`.

  The report ASSERTS ITS OWN ATTRIBUTION: `reconciled` is true only when every source
  landed on a hub carrying that source's own tag. Two sources legitimately sharing a hub
  that tags them both is counted as `shared_hubs`, not as a failure. See `reconcile/1`.
  """
  @impl Loopctl.Knowledge.StructuralLinksBehaviour
  @spec harvest(binary(), keyword()) ::
          {:ok, map()} | {:error, :heavy_read_overloaded}
  def harvest(tenant_id, opts \\ []) when is_binary(tenant_id) do
    floor = Keyword.get(opts, :min_siblings, min_siblings())

    case collect_sources(tenant_id, opts) do
      {:error, :heavy_read_overloaded} = shed ->
        shed

      {:ok, groups, without_source} ->
        {qualifying, skipped} =
          groups
          |> Enum.sort_by(fn {source, _ids} -> source end)
          |> Enum.split_with(fn {_source, ids} -> length(ids) >= floor end)

        blank = blank_report(skipped, without_source, floor, length(qualifying))

        case harvest_sources(tenant_id, qualifying, blank) do
          {:error, :heavy_read_overloaded} = shed ->
            shed

          {:ok, acc} ->
            report = reconcile(acc)
            log_report(tenant_id, report)
            {:ok, report}
        end
    end
  end

  # A shed HUB LOOKUP halts the whole tenant, exactly as a shed scan page does. The two
  # per-source lookups run on HeavyRead too, and folding their shed into `hub_failures`
  # made a load-shed run indistinguishable from a clean one: `harvest/2` returned
  # `{:ok, report}` with `reconciled: true`, the worker wrote a green audit entry, and the
  # shed sources got no hub and no edges until next Sunday. Halting restores the worker's
  # documented contract - "the whole tenant retries later".
  defp harvest_sources(tenant_id, qualifying, blank) do
    Enum.reduce_while(qualifying, {:ok, blank}, fn {source, ids}, {:ok, acc} ->
      case harvest_one_source(tenant_id, source, ids, acc) do
        {:error, :heavy_read_overloaded} = shed -> {:halt, shed}
        acc -> {:cont, {:ok, acc}}
      end
    end)
  end

  # ------------------------------------------------------------------
  # Scan — KEYSET-BATCHED, and that is not a refinement
  # ------------------------------------------------------------------

  # This used to be one `HeavyRead.all` selecting every published article of the tenant
  # with its `tags` array, then grouping the whole list in memory.
  #
  # That OOM-killed the production BEAM on the first real run (2026-08-20, 512MB machine:
  # "Out of memory: Killed process 647 (beam.smp)"). The row COUNT was not the problem —
  # ~79k ids is about a megabyte. The `tags` ARRAY was: every row dragged a list of tag
  # strings, and the whole decoded result set had to exist at once before a single group
  # could be formed.
  #
  # So the fix is not a bigger machine or a smaller corpus. It is to never hold the corpus:
  # read a bounded keyset page, reduce it IMMEDIATELY to `source => [id]` so the tags are
  # discarded with the page, and carry only the id map forward. Peak memory becomes one
  # page plus the ids, which is what the accumulation was always worth.
  #
  # A shed (`{:error, :heavy_read_overloaded}`) is propagated from any page — partial
  # grouping is not a usable answer, because a source that straddles two pages would be
  # counted short and could fall under the floor.
  defp collect_sources(tenant_id, opts) do
    batch = Keyword.get(opts, :scan_batch, @scan_batch)
    collect_pages(tenant_id, opts, batch, nil, %{}, 0)
  end

  defp collect_pages(tenant_id, opts, batch, after_id, groups, without_source) do
    case fetch_page(tenant_id, opts, batch, after_id) do
      {:error, :heavy_read_overloaded} = shed ->
        shed

      [] ->
        {:ok, groups, without_source}

      rows ->
        {groups, without_source} = reduce_page(rows, groups, without_source)
        last = rows |> List.last() |> Map.fetch!(:id)
        collect_pages(tenant_id, opts, batch, last, groups, without_source)
    end
  end

  # Reducing the page HERE, not at the call site, is what discards the `tags` arrays with
  # the page rather than carrying them to the end of the scan.
  defp reduce_page(rows, groups, without_source) do
    Enum.reduce(rows, {groups, without_source}, fn row, {acc, missing} ->
      case source_key(row) do
        nil -> {acc, missing + 1}
        key -> {Map.update(acc, key, [row.id], &[row.id | &1]), missing}
      end
    end)
  end

  defp fetch_page(tenant_id, opts, batch, after_id) do
    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        # A suppressed article is not a hub MEMBER: the hub exists to navigate to it, and
        # every other retrieval surface has stopped returning it. Excluding it here also
        # keeps `member_count` honest, since that number is what names the hub.
        where: is_nil(a.suppressed_at),
        where: is_nil(a.metadata["hub_kind"]),
        order_by: [asc: a.id],
        limit: ^batch,
        select: %{id: a.id, tags: a.tags, source_type: a.source_type, source_id: a.source_id}
      )

    query = if after_id, do: where(query, [a], a.id > ^after_id), else: query

    HeavyRead.all(
      tenant_id,
      query,
      opts |> Keyword.drop([:scan_batch, :min_siblings]) |> Keyword.merge(on_overload: :tag)
    )
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

  # ------------------------------------------------------------------
  # Hub + edges
  # ------------------------------------------------------------------

  defp harvest_one_source(tenant_id, source, member_ids, acc) do
    case resolve_or_create_hub(tenant_id, source, length(member_ids)) do
      {:ok, hub, outcome} when outcome in [:created, :resolved, :adopted] ->
        # Record WHICH hub this source landed on, and whether that hub carries the
        # source's own tag. The second is the reconciliation — see reconcile/1.
        acc = %{acc | hub_ids: MapSet.put(acc.hub_ids, hub.id)}
        counted = acc |> count_attribution(source, hub) |> count_outcome(outcome)

        # ...and an unattributed hub gets NO EDGES. Reporting the #724 merge while still
        # writing one `derived_from` edge per member to another source's hub records the
        # corruption instead of preventing it: an agent traversing those edges is told the
        # article came from a source it did not come from.
        if attributed?(source, hub),
          do: write_edges(tenant_id, hub, member_ids, counted),
          else: counted

      {:error, :heavy_read_overloaded} = shed ->
        shed

      {:error, reason} ->
        Logger.warning("structural_links: hub failed for #{source}: #{inspect(reason)}")
        %{acc | hub_failures: acc.hub_failures + 1}
    end
  end

  # A hub that does not carry the source's OWN tag is not that source's hub. Adoption and
  # creation both guarantee the tag; only a resolve handing back somebody ELSE's row can
  # break it, which is precisely the #724 merge. See reconcile/1.
  defp count_attribution(acc, source, hub) do
    if attributed?(source, hub),
      do: acc,
      else: %{acc | hubs_unattributed: acc.hubs_unattributed + 1}
  end

  defp attributed?(source, hub), do: source in (hub.tags || [])

  defp count_outcome(acc, :created), do: %{acc | hubs_created: acc.hubs_created + 1}
  defp count_outcome(acc, :resolved), do: %{acc | hubs_resolved: acc.hubs_resolved + 1}
  defp count_outcome(acc, :adopted), do: %{acc | hubs_adopted: acc.hubs_adopted + 1}

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
  defp resolve_or_create_hub(tenant_id, source, member_count) do
    key = hub_idempotency_key(source)

    case minted_hub(tenant_id, key) do
      {:error, _reason} = shed -> shed
      nil -> adopt_or_create_hub(tenant_id, source, key, member_count)
      hub -> {:ok, maybe_retitle(tenant_id, hub, source, member_count), :resolved}
    end
  end

  defp adopt_or_create_hub(tenant_id, source, key, member_count) do
    case existing_source_hub(tenant_id, source) do
      {:error, _reason} = shed -> shed
      nil -> create_hub(tenant_id, source, key, member_count)
      hub -> {:ok, hub, :adopted}
    end
  end

  # A hub minted before a name was derivable keeps its digest title forever otherwise.
  # Retitle ONLY when the stored title is still exactly the digest form we generated: that
  # way a name a human (or a later, better rule) put there is never overwritten by this.
  # The cheap predicates come FIRST: `hub_title/3` runs a full-corpus `unnest(tags)`
  # aggregate, and computing `desired` before consulting them paid for it on every
  # resolved hub of every weekly run, including the ones that were never ours to touch.
  defp maybe_retitle(tenant_id, hub, source, member_count) do
    if retitleable?(hub, source),
      do: retitle(tenant_id, hub, source, member_count),
      else: hub
  end

  # A hub that does not carry this source's own tag is NOT this source's hub — the #724
  # shape, where a row answering our idempotency_key belongs to somebody else. Renaming it
  # to our name destroys another source's title, re-embeds it, and repeats every week.
  defp retitleable?(hub, source), do: attributed?(source, hub) and ours_to_retitle?(hub, source)

  defp retitle(tenant_id, hub, source, member_count) do
    desired = "Source: " <> hub_title(tenant_id, source, member_count)
    metadata = hub.metadata || %{}
    retired = Map.get(metadata, "hub_titles_retired", [])

    if hub.title != desired and not digest_downgrade?(desired, source) and
         desired not in retired do
      attrs = %{
        title: desired,
        metadata:
          metadata
          |> Map.put("hub_title_generated", desired)
          |> Map.put("hub_titles_retired", Enum.uniq([hub.title | retired]))
      }

      case Knowledge.update_article(tenant_id, hub.id, attrs, @actor) do
        {:ok, updated} -> updated
        _ -> hub
      end
    else
      hub
    end
  end

  # Naming is MONOTONIC, and it has to be monotonic in BOTH directions a title can move.
  #
  # `digest_downgrade?/2` blocks name -> digest: `universal_tag/3` recomputes coverage
  # against the CURRENT member count, so a source that grows by a handful of untagged
  # articles drops under the 0.9 floor and the name it earned reverts to
  # "Source: doc a8d8cf71c5df".
  #
  # The retired-title ledger blocks name -> NAME -> the same name again, which the digest
  # rule never saw. `universal_tag/3` orders by `count(*) DESC`, so with two name-shaped
  # tags on one source, which one clears the floor flips as untagged and partially-tagged
  # members arrive: measured A -> B -> A across three runs. Correcting a bad generated
  # name is still allowed — moving FORWARD to a title we have not used before — but a
  # title this hub has already left is never returned to, so the oscillation terminates.
  # Every flip it prevents is an article.updated entry and a re-embedding not paid for.
  defp digest_downgrade?(desired, source), do: desired == "Source: " <> digest_title(source)

  # A stored title is ours to change only while it is exactly the one we last generated.
  # The moment anyone edits it, it stops being ours and we leave it alone forever.
  #
  # The `nil` clause is one-time compatibility for hubs minted before the marker existed:
  # those carry no record of what we wrote, so fall back to "it is ours if it still looks
  # generated" — the digest form, or any `Source: ` title on a row we created.
  defp ours_to_retitle?(%{metadata: %{"hub_title_generated" => generated}} = hub, _source),
    do: hub.title == generated

  defp ours_to_retitle?(hub, source),
    do:
      hub.title == "Source: " <> digest_title(source) or
        String.starts_with?(hub.title, "Source: ")

  # These are READS, so they belong on HeavyRead and not on AdminRepo's 3-connection pool,
  # which `ValidateWitnessHeader` needs on every authenticated request. One lookup per
  # qualifying source (313 on the live corpus), three tenant jobs at a time, would
  # otherwise queue the authenticated API behind the Sunday harvest. A shed lookup is
  # PROPAGATED, never coerced to nil: nil means "no hub exists" and would mint a rival
  # beside one that does.
  defp minted_hub(tenant_id, key) do
    HeavyRead.one(
      tenant_id,
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.idempotency_key == ^key,
        select: a
      ),
      on_overload: :tag
    )
  end

  # A SUPPRESSED article is not adoptable. Adoption is a different population from
  # minted_hub/2 — it keys off the `hub` TAG, so the agent-authored hubs it finds carry no
  # idempotency_key and the two lookups do NOT return the same row. Adopting a suppressed
  # one would centre the source group's navigational star on an article no read path
  # returns, and would suppress minting the replacement that would have fixed it. Skipping
  # it here mints a fresh hub instead, which is the same answer as if the suppressed one
  # had never been written.
  defp existing_source_hub(tenant_id, source) do
    HeavyRead.one(
      tenant_id,
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        where: is_nil(a.suppressed_at),
        where: ^source in a.tags,
        where: "hub" in a.tags,
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: 1,
        select: a
      ),
      on_overload: :tag
    )
  end

  defp create_hub(tenant_id, source, key, member_count) do
    # ONE naming query, not two: hub_title/3 runs a per-source `unnest(tags)` aggregate
    # and it was being paid twice per minted hub, for the title and for the marker below.
    title = "Source: #{hub_title(tenant_id, source, member_count)}"

    attrs = %{
      title: title,
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
      # Record the title WE generated. maybe_retitle/4 compares against this to decide
      # whether a stored title is still ours to change, which is what lets a bad
      # generated name be corrected later without ever overwriting a human's.
      metadata: %{
        "hub_kind" => "source",
        "source_key" => source,
        "hub_title_generated" => title
      }
    }

    # The novelty gate lives in `propose_article/3`, NOT here: `create_article/3` is the
    # direct, ungated path. That matters for this writer rather than being trivia — hubs
    # are structurally near-identical to one another by construction, so a gated create
    # would stage every one after the first as a draft and the harvest would silently
    # produce unpublished hubs. Using the ungated path is the deliberate choice; do not
    # "improve" this by routing it through propose_article.
    case Knowledge.create_article(tenant_id, attrs, @actor) do
      {:ok, %Article{} = hub} ->
        {:ok, hub, :created}

      # `create_article/3`'s THIRD success shape: our `idempotency_key` already exists, so
      # this IS our hub, returned unchanged. It is reachable whenever `minted_hub/2` missed
      # it — a lagging read replica (`REPLICA_DATABASE_URL`), or two harvests overlapping
      # outside Oban's 300s unique window. Mapping it to `{:error, ...}` logged "hub failed"
      # and wrote zero edges for a source whose hub was sitting right there.
      {:ok, :deduplicated, %Article{} = hub} ->
        {:ok, hub, :resolved}

      # A title collision is NOT this source's hub. It is a DIFFERENT source that happened
      # to compute the same name, and returning it here merged them: measured on the live
      # corpus, one "Source: synology netbackup" node ended up serving 85 distinct sources
      # and 6,471 members, at which point a derived_from edge no longer means "derived from
      # this source" but "derived from something that shared a name" — which is exactly the
      # precision the whole feature exists to add.
      #
      # Names are not unique and were never going to be: the naming rule picks a tag every
      # member shares, and a collection tag like `synology-netbackup` is universal across
      # every document in that share. So disambiguate with the digest, which IS unique, and
      # keep the readable name in front of it.
      {:error, :duplicate_title, _other_sources_hub} ->
        create_hub_disambiguated(tenant_id, source, key, member_count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_hub_disambiguated(tenant_id, source, key, member_count) do
    name = hub_title(tenant_id, source, member_count)
    digest = digest_title(source)

    title =
      if name == digest, do: "Source: #{digest}", else: "Source: #{name} (#{digest})"

    attrs = %{
      title: title,
      body: hub_body(source),
      category: "reference",
      status: :published,
      tags: [source, "hub", "source-hub"],
      idempotency_key: key,
      metadata: %{
        "hub_kind" => "source",
        "source_key" => source,
        "hub_title_generated" => title
      }
    }

    # Same three shapes as `create_hub/4`. The disambiguated title carries the source's own
    # unique digest, so a collision on it — by key or by title — is this source's own hub,
    # not another's; `attributed?/2` still re-checks the tag before any edge is written.
    case Knowledge.create_article(tenant_id, attrs, @actor) do
      {:ok, %Article{} = hub} -> {:ok, hub, :created}
      {:ok, :deduplicated, %Article{} = hub} -> {:ok, hub, :resolved}
      {:error, :duplicate_title, %Article{} = hub} -> {:ok, hub, :resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_edges(tenant_id, hub, member_ids, acc) do
    # ArticleLink.inserted_at is :utc_datetime_usec — truncating to :second makes Ecto
    # raise on dump. It also has no updated_at (links are immutable), so only one stamp.
    now = DateTime.utc_now()

    # `member_ids` are bare ids, not rows: the batched scan discards everything except the
    # id as each page is reduced, which is what keeps peak memory bounded.
    rows =
      member_ids
      |> Enum.reject(&(&1 == hub.id))
      |> Enum.map(
        &%{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          source_article_id: &1,
          target_article_id: hub.id,
          relationship_type: :derived_from,
          metadata: %{"origin" => "structural_links"},
          inserted_at: now
        }
      )

    # CHUNKED. Seven bind parameters per row against Postgres's hard 65,535-parameter wire
    # ceiling puts the raise at 9,363 members, and the live corpus already carries a
    # 6,471-member source. Unattended (#725) that raise is a discarded Oban job and a
    # tenant that silently stops getting hubs.
    inserted =
      rows
      |> Enum.chunk_every(@edge_insert_chunk)
      |> Enum.reduce(0, fn chunk, total ->
        {count, _} =
          AdminRepo.insert_all(ArticleLink, chunk,
            on_conflict: :nothing,
            conflict_target: [
              :tenant_id,
              :source_article_id,
              :target_article_id,
              :relationship_type
            ]
          )

        total + count
      end)

    %{acc | edges_created: acc.edges_created + inserted}
  end

  # ------------------------------------------------------------------
  # Naming, config, reporting
  # ------------------------------------------------------------------

  defp hub_idempotency_key(source), do: "structural-hub-" <> source

  # The tag IS the name we have. Strip the family prefix for readability and leave the
  # digest — see the comment in create_hub/3 about never inventing a title.
  # Name the hub from a tag its members UNIVERSALLY share, or abstain to the digest.
  #
  # The digest names the first 17 hubs produced ("Source: doc a8d8cf71c5df") and they are
  # poor articles: published, searchable, and telling a reader nothing about what the
  # source is. The corpus can usually do better, because the extraction skills tag every
  # member of a source with something identifying — measured 2026-08-20:
  #
  #   book-9baec82a16b7  -> chris-mccord-bruce-tate-jos-valim   813/813 members
  #   doc-d690c97f3116   -> iota                                416/416
  #   doc-a8d8cf71c5df   -> synology-netbackup                 1404/1404
  #   book-aca9eec5858f  -> nothing universal (top real tag `scalability` covers 19/338)
  #
  # That last row is why the rule is UNIVERSALITY and not popularity. "Most common tag"
  # would have titled a 338-article source "scalability" on 6% coverage — a confident,
  # wrong name, which is worse than a digest because it reads as a fact. So a candidate
  # must cover at least @hub_name_coverage of the members, structural and format tags are
  # excluded, and when nothing qualifies the digest stands. Never invent a name.
  defp hub_title(tenant_id, source, member_count) do
    case universal_tag(tenant_id, source, member_count) do
      nil -> digest_title(source)
      tag -> if name_shaped?(tag), do: humanize_tag(tag), else: digest_title(source)
    end
  end

  defp digest_title(source) do
    Enum.reduce(@source_tag_prefixes, source, fn prefix, acc ->
      String.replace_prefix(acc, prefix, String.trim_trailing(prefix, "-") <> " ")
    end)
  end

  defp humanize_tag(tag), do: tag |> String.replace("-", " ") |> String.trim()

  # Universality is necessary and NOT sufficient — a junk tag can sit on 100% of members.
  # Measured on the first 17 retitles: 5 improved, 9 correctly abstained, and 3 came out
  # WORSE than the digest they replaced:
  #
  #   2222-location-reporting-sometimes-goes-w   a truncated sentence used as a tag
  #   administrator                              PDF document-property metadata
  #   dropbox                                    the storage provider, not the source
  #
  # The stoplist handles the identity/format words. This handles the shape: a real source
  # name does not begin with a number, does not trail off in a one-letter word (the tell
  # of truncation), and is not a sentence. Anything failing that falls back to the digest,
  # which is uninformative but at least never wrong.
  defp name_shaped?(tag) do
    words = String.split(tag, "-", trim: true)

    String.length(tag) <= 48 and
      length(words) <= 6 and
      not String.match?(tag, ~r/^\d/) and
      not Enum.any?(words, &(String.length(&1) < 2))
  end

  # Raw SQL rather than Ecto here for one reason: this aggregates over `unnest(tags)`, and
  # the Postgres adapter cannot select from a fragment join. Every value is a bound
  # parameter — nothing is interpolated — and the result is a single row.
  defp universal_tag(tenant_id, source, member_count) when member_count > 0 do
    threshold = ceil(member_count * @hub_name_coverage)

    sql = """
    SELECT t
    FROM articles a, unnest(a.tags) AS t
    WHERE a.tenant_id = $1
      AND a.status = 'published'
      AND (a.metadata->>'hub_kind') IS NULL
      AND $2 = ANY(a.tags)
      AND NOT (t = ANY($3))
      AND t NOT LIKE 'book-%'
      AND t NOT LIKE 'doc-%'
      AND t NOT LIKE 'repo-%'
      AND t NOT LIKE 'yt-%'
      AND t NOT LIKE 'pp-%'
    GROUP BY t
    HAVING count(*) >= $4
    ORDER BY count(*) DESC, length(t) DESC, t ASC
    LIMIT 1
    """

    with {:ok, tid} <- Ecto.UUID.dump(tenant_id),
         %{rows: [[tag]]} <-
           naming_scan(tenant_id, sql, [tid, source, @hub_name_stoplist, threshold]) do
      tag
    else
      _ -> nil
    end
  end

  defp universal_tag(_tenant_id, _source, _member_count), do: nil

  # This is the HEAVIEST query in the harvest — a full `unnest(tags)` aggregate over the
  # tenant's published corpus, once per qualifying source (313 on the live corpus, three
  # tenant jobs at a time). It belongs on the heavy-read pool for the same reason the scan
  # and the hub lookups do: AdminRepo's 3 connections are what `ValidateWitnessHeader`
  # needs on every authenticated request, so running it there queues the API behind the
  # Sunday harvest. Gated through `HeavyRead.with_slot/3` so it is counted against the
  # tenant's in-flight budget rather than slipping past it as raw SQL.
  #
  # A shed ABSTAINS to the digest rather than propagating: a name is an improvement, never
  # a correctness condition, and the ledger in `retitle/4` lets the next run upgrade it.
  defp naming_scan(tenant_id, sql, params) do
    HeavyRead.with_slot(tenant_id, [on_overload: :tag], fn ->
      SQL.query!(HeavyRead.repo_for(nil), sql, params)
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

  defp blank_report(skipped, without_source, floor, qualifying) do
    %{
      hubs_created: 0,
      hubs_resolved: 0,
      hubs_adopted: 0,
      hub_failures: 0,
      hubs_unattributed: 0,
      edges_created: 0,
      sources_below_floor: length(skipped),
      articles_without_source: without_source,
      min_siblings: floor,
      sources_qualifying: qualifying,
      # Bounded by the qualifying source count (313 at floor 25 on the live corpus,
      # 3,713 at floor 3) — a set of UUIDs at that scale is nothing, and unlike the
      # scan it never holds an article row.
      hub_ids: MapSet.new()
    }
  end

  # The run asserts its own arithmetic (#725), and the assertion that matters is
  # ATTRIBUTION: every source must land on a hub carrying that source's OWN tag.
  #
  # That is the #724 merge in one predicate. `duplicate_title` was once mapped to
  # "resolved", so 85 distinct sources with 6,471 members between them all landed on
  # "Source: synology netbackup" — a node tagged for exactly one of them — at which point
  # a `derived_from` edge means "derived from something that shared a name". Every count
  # in the report looked healthy throughout, which is why this must be computed.
  #
  # What is NOT a defect and must not be reported as one: two sources SHARING a hub that
  # tags them both. An article carrying two source tags and the `hub` tag is legitimately
  # adoptable by both (1,195 dual-tagged articles measured on the live corpus), so a
  # tenant-wide `distinct_hubs < linked` verdict would sit permanently false on a healthy
  # corpus and the weekly :error log would be pure noise — an alarm that is always on
  # detects nothing. Sharing is counted as `shared_hubs` and kept OUT of the verdict.
  #
  # `created + resolved + adopted + failed == sources_qualifying` is deliberately not
  # checked: harvest_one_source/4 increments exactly one counter per qualifying source, so
  # it holds by construction and could never fail.
  #
  # A mismatch is REPORTED, never raised — but it is also ACTED ON before it gets here:
  # `harvest_one_source/4` computes attribution BEFORE the write and skips the edges for an
  # unattributed hub, so the count below records sources that were REFUSED rather than
  # sources that were corrupted. `reconciled: false` rides in the report, the log line and
  # the worker's audit entry; a crash here would only lose the finding.
  defp reconcile(report) do
    linked = report.hubs_created + report.hubs_resolved + report.hubs_adopted
    distinct = MapSet.size(report.hub_ids)

    report
    |> Map.delete(:hub_ids)
    |> Map.put(:distinct_hubs, distinct)
    |> Map.put(:shared_hubs, linked - distinct)
    |> Map.put(:reconciled, report.hubs_unattributed == 0)
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
        "hub_failures=#{report.hub_failures} " <>
        "sources_qualifying=#{report.sources_qualifying} " <>
        "distinct_hubs=#{report.distinct_hubs} shared_hubs=#{report.shared_hubs} " <>
        "hubs_unattributed=#{report.hubs_unattributed} reconciled=#{report.reconciled}"
    )

    unless report.reconciled do
      Logger.error(
        "structural_links RECONCILIATION FAILED: tenant=#{tenant_id} " <>
          "hubs_unattributed=#{report.hubs_unattributed} of " <>
          "#{report.sources_qualifying} qualifying sources. A source landed on a hub that " <>
          "does not carry that source's tag, so its derived_from edges no longer mean " <>
          "'derived from this source' — inspect before trusting this run's edges. " <>
          "(shared_hubs=#{report.shared_hubs} is the benign dual-tagged shape, not this.)"
      )
    end
  end
end
