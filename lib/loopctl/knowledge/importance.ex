defmodule Loopctl.Knowledge.Importance do
  @moduledoc """
  Stamps `articles.read_day_count` — the USAGE signal the importance ranking prior reads
  (#790) — once a night, from the same `article_access_events` rows the heat index
  aggregates.

  ## Why a stamped column and not a live read

  `Loopctl.Knowledge.RankingPriors` is PURE and `Knowledge.merge_results/5` must stay
  DB-free, so the prior cannot call `heat_index/2` at merge time: that is a `HeavyRead`
  aggregate plus an `AdminRepo` projection under a split node-level pool bound, on the
  request path, per query. The value is therefore stored on the row and projected onto the
  result map, exactly as `:category`, `:content_changed_at`, `:tags` and `:idempotency_key`
  already are.

  Stamped at CONSOLIDATION time and never per write, per Richmond Alake's Day 5-II rule
  ("stamp importance while the model's attention is already on the material"): the
  alternative — scoring on every write — is a cost you pay always for value you collect
  occasionally. Nothing here calls a model at all; importance is measured, not judged.

  ## What is counted

  DISTINCT UTC DAYS on which the article received a caller-chosen body read
  (`Knowledge.heat_read_access_types/0`) inside the window. Three things this is NOT, each
  for a reason the heat index has already paid for:

    * NOT raw read counts. That is the pinning defect of #567/#569/#572 — an article can
      inflate its own rank with a `knowledge_get` loop, and a day counts once however long
      the loop runs, so sustained use outranks a burst.
    * NOT distinct readers. `heat_counts_query/5` records why in its own comment: "under a
      fleet sharing one key EVERY article ties at 1". Readership is near-flat here; days
      still carry signal.
    * NOT drills. `knowledge_progressive_drill` records its own uncounted access type, so
      being SHOWN by an index cannot produce the rank that showed it. This module inherits
      that exclusion by reading `Knowledge.heat_read_access_types/0` rather than restating
      the list — a second, wider copy of that list is exactly how #563/#569/#572 happened.

  ## What it writes, and what it deliberately does not

  Two `update_all` statements per run: one that SETS the measured counts, one that CLEARS
  rows that fell out of the window. `update_all` and not a changeset, for two reasons — the
  column is in no `cast` list (it is a ranking input; see `Article`), and a changeset write
  would bump `updated_at` on every read article every night. `content_changed_at` is
  untouched on both paths, because being read is not being edited, and `updated_at` is left
  alone so the staleness lint keeps meaning what it says.

  It never stamps a SYSTEM CANONICAL. Both statements carry `a.tenant_id == ^tenant_id`, and
  a canonical's `tenant_id` is NULL, so it is excluded structurally rather than by
  convention: `read_day_count` is one column on a row several tenants read, and no single
  tenant's usage may decide a shared row's rank for the others. A canonical therefore stays
  NULL, which is exactly neutral.

  ## Isolation

  The aggregate runs through `Loopctl.HeavyRead` (the `:consolidation` endpoint, the same
  gate and statement timeout the nightly pass's other whole-corpus reads use) with a
  conjunctive `e.tenant_id == ^tenant_id`, which is what `HeavyRead.guard!/2` requires. The
  writes run on `AdminRepo`, where RLS does nothing and the explicit `tenant_id` predicate
  IS the isolation — carried on both statements. An event row can only name an article its
  own tenant read, and the write predicate refuses to act on any other tenant's row even if
  one did.

  ## Fail-soft

  `stamp/2` returns a tally and never raises: it runs inside a nightly pass whose other
  steps have already committed, and a lost stamp costs one night of ranking freshness — the
  cheapest thing in the run to lose. A shed heavy read is reported as its own gate value
  rather than as zero work.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.ExitTag
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleAccessEvent

  # Shares the heat index's default lookback so "used recently" means one thing across the
  # product. A caller may narrow or widen it with `:since`; there is no separate config key,
  # because two windows that could drift is a worse failure than a window that cannot be
  # tuned without a deploy.
  @window_days Knowledge.heat_default_window_days()

  # The most articles one run will stamp. The aggregate's cost tracks articles READ in the
  # window, not corpus size — measured at 1,256 distinct articles over 90 days on the
  # 79k-article production tenant (the EXPLAIN in `heat_counts_query/5`'s comment) — so this
  # is ~8x headroom rather than a limit anyone is expected to hit.
  #
  # It bounds the CLEAR statement's parameter list as much as the write: the clear is a
  # single `NOT IN (<measured ids>)`, which cannot be chunked (each chunk would clear the
  # rows another chunk measured). Truncation keeps the MOST-read articles, so what a
  # truncated run clears is the tail — one-sided-safe, since clearing sets a row back to
  # exactly neutral, and self-correcting on the next run.
  @max_stamped_articles 10_000

  @typedoc "The per-run tally. `gate` is `:open` on a run that read the events table."
  @type tally :: %{
          stamped: non_neg_integer(),
          cleared: non_neg_integer(),
          truncated: boolean(),
          gate: :open | :heavy_read_overloaded | :scan_failed | :write_failed
        }

  @doc """
  Stamps this tenant's `read_day_count` from its access events and returns a tally.

  Opts:

    * `:since` — window start (default: #{@window_days} days before the start of today,
      UTC). Snapped to a UTC day boundary when derived, taken verbatim when supplied, for
      the reason `heat_since/1` gives: a system-derived window that moves by a microsecond
      per call makes two runs incomparable, while a caller's explicit value is a per-call
      value already.
    * `:now` — the clock, for deterministic tests.
  """
  @spec stamp(Ecto.UUID.t(), keyword()) :: tally()
  def stamp(tenant_id, opts \\ []) when is_binary(tenant_id) do
    since = window_start(opts)

    case measure(tenant_id, since) do
      {:ok, measured} -> write(tenant_id, measured)
      {:error, gate} -> tally(gate)
    end
  end

  @doc """
  The distinct-read-day window this stamp measures over, in days.

  Public so the `Article` docs, the tests and any operator tooling read ONE number rather
  than three copies of 90.
  """
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc "The per-run article cap. Public for the same single-source reason as `window_days/0`."
  @spec max_stamped_articles() :: pos_integer()
  def max_stamped_articles, do: @max_stamped_articles

  # --- measurement -----------------------------------------------------------

  defp measure(tenant_id, since) do
    query = read_days_query(tenant_id, since)

    case HeavyRead.all(tenant_id, query, heavy_opts()) do
      {:error, :heavy_read_overloaded} -> {:error, :heavy_read_overloaded}
      rows when is_list(rows) -> {:ok, rows}
    end
  rescue
    e -> scan_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> scan_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  # Aggregate over the EVENTS alone — no join to `articles`, so no article column enters the
  # group key and the read stays on the events index. The article-side scoping happens on the
  # WRITE, where the `tenant_id` predicate has to be anyway.
  #
  # The day is cut in UTC EXPLICITLY, exactly as `heat_counts_query/5` does it: a bare
  # `::date` cast resolves in the connection's `TimeZone` GUC, so on a backend whose session
  # timezone is not UTC this would count days on a boundary the UTC-snapped window does not
  # use — the same value measured against two different calendars.
  #
  # Ordered by count desc then id, so a run that hits the cap keeps the most-used articles
  # and keeps doing so deterministically between runs.
  defp read_days_query(tenant_id, since) do
    from(e in ArticleAccessEvent,
      where: e.tenant_id == ^tenant_id,
      where: e.access_type in ^Knowledge.heat_read_access_types(),
      where: e.accessed_at >= ^since,
      group_by: e.article_id,
      order_by: [
        desc: count(fragment("((? at time zone 'UTC'))::date", e.accessed_at), :distinct),
        asc: e.article_id
      ],
      limit: ^(@max_stamped_articles + 1),
      select: %{
        article_id: e.article_id,
        read_days: count(fragment("((? at time zone 'UTC'))::date", e.accessed_at), :distinct)
      }
    )
  end

  # --- writes ----------------------------------------------------------------

  defp write(tenant_id, measured) do
    truncated = length(measured) > @max_stamped_articles
    kept = Enum.take(measured, @max_stamped_articles)

    log_truncation(tenant_id, truncated)

    stamped = Enum.sum(Enum.map(group_by_days(kept), &set_count(tenant_id, &1)))
    cleared = clear_absent(tenant_id, Enum.map(kept, & &1.article_id))

    %{tally(:open) | stamped: stamped, cleared: cleared, truncated: truncated}
  rescue
    e -> write_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> write_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  # One statement per DISTINCT day-count rather than one per article: the count is bounded by
  # the window (at most #{@window_days} distinct values), so a tenant with thousands of read
  # articles still costs tens of statements, not thousands.
  defp group_by_days(kept) do
    kept
    |> Enum.group_by(& &1.read_days, & &1.article_id)
    |> Enum.map(fn {days, ids} -> {days, ids} end)
  end

  # `is_distinct_from` rather than a bare inequality, and it is not cosmetic: `read_day_count`
  # is NULL on every row that has never been stamped, and `<> ` against NULL is NULL, so a
  # plain inequality would match nothing and the first night would write no rows at all.
  # Skipping unchanged rows keeps a steady-state night's write set to what actually moved.
  defp set_count(tenant_id, {days, ids}) do
    {count, _} =
      AdminRepo.update_all(
        from(a in Article,
          where: a.tenant_id == ^tenant_id,
          where: a.id in ^ids,
          where: fragment("? IS DISTINCT FROM ?", a.read_day_count, ^days)
        ),
        set: [read_day_count: days]
      )

    count
  end

  # Rows that HAD a count and no longer earn one: the article fell out of the window. Cleared
  # to NULL rather than 0 because the two are the same neutral state (`RankingPriors`
  # `read_day_count/1` reads both as 0) and NULL is the one that says "not measured".
  #
  # Scoped to `read_day_count IS NOT NULL`, so a corpus of never-stamped articles costs no
  # writes at all — the whole-corpus reconciliation touches only rows that would otherwise
  # keep a boost they no longer earn.
  defp clear_absent(tenant_id, []) do
    {count, _} =
      AdminRepo.update_all(
        from(a in Article,
          where: a.tenant_id == ^tenant_id,
          where: not is_nil(a.read_day_count)
        ),
        set: [read_day_count: nil]
      )

    count
  end

  defp clear_absent(tenant_id, ids) do
    {count, _} =
      AdminRepo.update_all(
        from(a in Article,
          where: a.tenant_id == ^tenant_id,
          where: not is_nil(a.read_day_count),
          where: a.id not in ^ids
        ),
        set: [read_day_count: nil]
      )

    count
  end

  # --- window ----------------------------------------------------------------

  defp window_start(opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = given -> given
      nil -> default_window_start(Keyword.get(opts, :now, DateTime.utc_now()))
    end
  end

  defp default_window_start(now) do
    now
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-@window_days, :day)
  end

  # --- tallies and logging ---------------------------------------------------

  defp heavy_opts do
    # The `:consolidation` endpoint, deliberately, rather than a new one: this read runs
    # inside that pass, on the same schedule, with the same profile (a bounded aggregate over
    # a nightly window), so it belongs under the same gate weight and statement timeout. A
    # new endpoint atom would also have to be partitioned in the TenantGate drift guard, for
    # a read that is not a new class of work.
    Keyword.put(HeavyRead.opts(:consolidation), :on_overload, :tag)
  end

  defp tally(gate) do
    %{stamped: 0, cleared: 0, truncated: false, gate: gate}
  end

  defp scan_failed(tenant_id, tag) do
    Logger.error(
      "Knowledge.Importance: tenant=#{tenant_id} usage scan failed (#{tag}); " <>
        "read_day_count keeps last night's values and ranking is unchanged."
    )

    {:error, :scan_failed}
  end

  defp write_failed(tenant_id, tag) do
    Logger.error(
      "Knowledge.Importance: tenant=#{tenant_id} usage stamp write failed (#{tag}); " <>
        "the corpus may be PARTIALLY stamped this run (the set and clear statements are " <>
        "not one transaction). Both are idempotent, so the next run reconciles it."
    )

    tally(:write_failed)
  end

  defp log_truncation(_tenant_id, false), do: :ok

  defp log_truncation(tenant_id, true) do
    Logger.warning(
      "Knowledge.Importance: tenant=#{tenant_id} read more than #{@max_stamped_articles} " <>
        "distinct articles in the window; the least-used tail is cleared to neutral rather " <>
        "than stamped. Raise @max_stamped_articles if this is steady state."
    )
  end
end
