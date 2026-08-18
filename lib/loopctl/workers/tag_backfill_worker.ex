defmodule Loopctl.Workers.TagBackfillWorker do
  @moduledoc """
  Re-tags existing articles CONCURRENTLY, against the vocabulary the corpus already uses.

  Tags were LLM-generated once at ingest and nothing ever revisited them, so there was no way
  to improve an article's tags after capture at all. This is that way.

  ## What it selects, and why not "everything"

  By fewest topical tags first. Coverage is mostly fine — the hosted corpus averages 8.66
  topical tags per article and only 46 published articles carry fewer than three — so a run
  that swept everything would spend thousands of provider calls to add near-synonyms to
  articles that are already well tagged, which makes the vocabulary fragmentation WORSE. The
  ordering means a bounded run does the articles that actually lack tags first, and a
  `min_tags` filter lets an operator stop there.

  ## Concurrency

  `Task.async_stream` with a small bound. Each article costs one provider call, so a
  sequential backfill over even a few thousand articles is a few thousand serial round trips.
  The bound is small because the constraint is a shared provider rate limit and the AdminRepo
  pool, not CPU here. `timeout: :infinity` on the stream with the real bound coming from the
  provider client — a stream timeout would kill the task and lose the work while the request
  kept running and got billed.

  ## Idempotent and resumable

  Every article it touches gets `metadata["retagged_at"]`, and the selection skips anything
  already carrying it. So a run that dies halfway resumes where it stopped, a re-run is a
  no-op, and there is no separate cursor to get out of step with the corpus.

  ## It never removes a tag

  `Tagger.merge/2` appends. Existing tags carry provenance ids and the reserved `idem-`
  namespace a sourcer reads to know an article was already captured — dropping one causes a
  re-capture, not a cosmetic regression.

  ## Running it

      Loopctl.Workers.TagBackfillWorker.enqueue_all_tenants(limit: 200)
      Loopctl.Workers.TagBackfillWorker.new(%{"tenant_id" => id, "limit" => 200}) |> Oban.insert()

  Deliberately NOT on a cron. It is a backfill with a per-article provider cost, so it is
  started on purpose and bounded per run, rather than discovering its own budget nightly.
  """

  use Oban.Worker, queue: :knowledge, max_attempts: 3

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ProvenanceTags
  alias Loopctl.Knowledge.Tagger
  alias Loopctl.Tenants.Tenant

  require Logger

  @default_limit 200
  @default_min_tags 3

  @doc "Enqueue one job per active tenant."
  @spec enqueue_all_tenants(keyword()) :: :ok
  def enqueue_all_tenants(opts \\ []) do
    %{"mode" => "all_tenants", "limit" => Keyword.get(opts, :limit, @default_limit)}
    |> __MODULE__.new()
    |> Oban.insert()

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"} = args}) do
    limit = Map.get(args, "limit", @default_limit)

    from(t in Tenant, where: t.status == :active, select: t.id)
    |> AdminRepo.all()
    |> Enum.each(fn tenant_id ->
      %{"tenant_id" => tenant_id, "limit" => limit} |> __MODULE__.new() |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id} = args}) do
    limit = Map.get(args, "limit", @default_limit)
    min_tags = Map.get(args, "min_tags", @default_min_tags)

    {:ok, backfill(tenant_id, limit: limit, min_tags: min_tags)}
  end

  @doc """
  Re-tag up to `:limit` articles for a tenant. Returns a summary map.

  Public so an operator can run it from a release console and see what it did, rather than
  inferring a backfill's progress from log lines.
  """
  @spec backfill(Ecto.UUID.t(), keyword()) :: %{
          candidates: non_neg_integer(),
          retagged: non_neg_integer(),
          tags_added: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def backfill(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    vocabulary = established_vocabulary(tenant_id)
    candidates = candidates(tenant_id, limit, Keyword.get(opts, :min_tags, @default_min_tags))

    results =
      candidates
      |> Task.async_stream(
        fn article -> retag_one(tenant_id, article, vocabulary, opts) end,
        max_concurrency: concurrency(),
        timeout: :infinity,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{retagged: 0, tags_added: 0, skipped: 0}, fn
        {:ok, {:ok, added}}, acc when added > 0 ->
          %{acc | retagged: acc.retagged + 1, tags_added: acc.tags_added + added}

        _other, acc ->
          %{acc | skipped: acc.skipped + 1}
      end)

    Map.put(results, :candidates, length(candidates))
  end

  @doc """
  The tenant's ESTABLISHED tag vocabulary: topical tags ordered by how many articles use them.

  Ordered by usage on purpose. Showing a model the whole 60,141-tag vocabulary would be both
  enormous and useless — the point is to offer the tags that already GROUP things, and a tag
  used once groups nothing.

  **NON-TOPICAL tags are excluded, and that exclusion is the difference between this working
  and actively harming the corpus.** Provenance families name a source rather than a subject.
  STRUCTURAL tags name a format: measured 2026-08-18, the hosted corpus's most-used tags
  began `reference, document, pdf, book, youtube` — so an unfiltered vocabulary teaches the
  model to tag FORMAT instead of SUBJECT, which is the opposite of the point. A verification
  run against production with the unfiltered list added `document` and `code` to real
  articles before this was caught.
  """
  @spec established_vocabulary(Ecto.UUID.t(), pos_integer()) :: [String.t()]
  def established_vocabulary(tenant_id, limit \\ 150) do
    pattern = ProvenanceTags.sql_pattern()

    # Over-fetch, then filter structural tags in Elixir against the SAME predicate the MOC
    # worker uses. Passing the ~70-item list as a SQL array would work too, but then the
    # two consumers would agree only by coincidence — `ProvenanceTags.topical?/1` is the one
    # definition, and it cannot drift from itself.
    """
    SELECT tag FROM (
      SELECT unnest(tags) AS tag FROM articles
      WHERE tenant_id = $1 AND status = 'published'
    ) t
    WHERE tag !~ $2
    GROUP BY tag
    ORDER BY count(*) DESC, tag
    LIMIT $3
    """
    |> AdminRepo.query([Ecto.UUID.dump!(tenant_id), pattern, limit * 3])
    |> case do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(&hd/1) |> Enum.filter(&ProvenanceTags.topical?/1) |> Enum.take(limit)

      {:error, _} ->
        []
    end
  end

  defp candidates(tenant_id, limit, min_tags) do
    pattern = ProvenanceTags.sql_pattern()

    # Fewest TOPICAL tags first — provenance ids inflate the raw array length, so ordering on
    # `array_length(tags, 1)` would rank a heavily-sourced article as well-tagged.
    """
    SELECT id, title, body, tags
    FROM articles a
    WHERE a.tenant_id = $1
      AND a.status = 'published'
      AND (a.metadata->>'retagged_at') IS NULL
      AND (SELECT count(*) FROM unnest(a.tags) x WHERE x !~ $2) < $3
    ORDER BY (SELECT count(*) FROM unnest(a.tags) x WHERE x !~ $2), a.id
    LIMIT $4
    """
    |> AdminRepo.query([Ecto.UUID.dump!(tenant_id), pattern, min_tags, limit])
    |> case do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, title, body, tags] ->
          %{id: Ecto.UUID.load!(id), title: title, body: body, tags: tags || []}
        end)

      {:error, reason} ->
        Logger.warning("tag backfill: candidate query failed: #{inspect(reason)}")
        []
    end
  end

  defp retag_one(tenant_id, article, vocabulary, opts) do
    case Tagger.retag(tenant_id, article, vocabulary, opts) do
      {:ok, _tags, []} ->
        # Nothing to add. Still stamp it, or the article sits at the head of every future
        # run's fewest-tags-first ordering and is paid for again on every pass.
        stamp_only(tenant_id, article)
        {:ok, 0}

      {:ok, tags, added} ->
        case write_tags(tenant_id, article, tags) do
          {:ok, _} -> {:ok, length(added)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        # NOT stamped: a provider failure must leave the article eligible for the next run.
        {:error, reason}
    end
  end

  # Tags and the stamp in ONE statement. `metadata` is MERGED rather than replaced: a
  # whole-map write would drop `doc_id`, source fields and anything else a capture put there
  # — the same defect that made `lifecycle_entered_at` a column instead of a metadata key.
  defp write_tags(tenant_id, article, tags),
    do: touch(tenant_id, article, tags: tags, bump_updated_at: true)

  # Nothing was added, so no `updated_at` bump — touching it would move the article in the
  # recency prior for a write that changed nothing. It is still stamped, or it sits at the
  # head of every future run's fewest-tags-first ordering and gets paid for again each pass.
  defp stamp_only(tenant_id, article),
    do: touch(tenant_id, article, tags: nil, bump_updated_at: false)

  defp touch(tenant_id, article, opts) do
    now = DateTime.utc_now()
    stamp = DateTime.to_iso8601(now)

    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id == ^article.id,
        update: [
          set: [
            metadata:
              fragment(
                "coalesce(?, '{}'::jsonb) || jsonb_build_object('retagged_at', ?::text)",
                a.metadata,
                ^stamp
              )
          ]
        ]
      )

    query
    |> maybe_set_tags(opts[:tags])
    |> maybe_bump(opts[:bump_updated_at], now)
    |> AdminRepo.update_all([])
    |> case do
      {count, _} when count > 0 -> {:ok, count}
      _ -> {:error, :not_updated}
    end
  end

  defp maybe_set_tags(query, nil), do: query
  defp maybe_set_tags(query, tags), do: update(query, set: [tags: ^tags])

  defp maybe_bump(query, true, now), do: update(query, set: [updated_at: ^now])
  defp maybe_bump(query, _false, _now), do: query

  defp concurrency,
    do: Application.get_env(:loopctl, :knowledge_tag_backfill_concurrency, 4)
end
