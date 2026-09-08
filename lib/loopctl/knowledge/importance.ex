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
      still carry signal. Readership is not IGNORED, though — it BOUNDS the count rather than
      being the count: an article's days are capped at `solo_reader_day_cap/0` per distinct
      principal. Days defeat a same-day loop and NOT a daily one, so a single key running one
      `knowledge_get` a day would otherwise walk to the ceiling on its own; that cap is what
      stops it, and it is why the aggregate still joins `api_keys`.
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
  tenant's usage may decide a shared row's rank for the others.

  A canonical therefore stays NULL, and NULL is neutral in SCORE but not in RANK. That is a
  ranking defect on its own and is NOT fixed here: a pool that mixes tenant rows (measured)
  with canonicals (structurally unmeasurable) would be ranked on a number that means
  different things per row — the counted-vs-uncounted asymmetry #569/#572 each fixed once,
  with the direction reversed. It is handled on the READ side instead, by
  `RankingPriors.pool_importance_default_factor/4`: a candidate this stamp could not have
  reached is scored at the MEDIAN factor of the pool's measured candidates, so it is placed
  at the centre of the population it is being ranked against rather than at its floor. Fix it
  properly by making canonicals MEASURABLE per tenant (a per-(tenant, article) usage row),
  never by stamping the shared column, and never by turning the prior off for the whole pool
  — the canon is the bulk of this corpus, so that is a product-wide disablement wearing a
  narrow gate's clothes.

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
  alias Loopctl.Auth.ApiKey
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
  # exactly neutral.
  #
  # It does NOT self-correct on the next run, and do not read it as if it did: the ordering
  # (the capped count desc, raw days, then id) is deterministic, so the SAME tail falls off
  # every night for as long as the tenant stays over the cap. An article genuinely read on one
  # or two days in the window is then permanently neutral rather than briefly so. The cost is
  # a lost boost and never a demotion; the remedy is raising this number, which is what
  # `log_truncation/3` says.
  @max_stamped_articles 10_000

  # The most distinct days ONE principal can contribute to an article's count. The article's
  # ceiling is this number TIMES its distinct principals — `least(days, cap * readers)` — so
  # the cap scales with readership instead of switching off.
  #
  # Distinct days defeat the same-day `knowledge_get` loop #567 was filed for and do NOT
  # defeat a DAILY one: a single key running one read a day walks to the saturation point on
  # its own, and this prior feeds every ranked read path in the tenant rather than one
  # advisory browse list. So a principal — `coalesce(k.agent_id, e.api_key_id)`, the same
  # reader identity `heat_counts_query/5` counts, agent-first because v2 mints a key per
  # dispatch — buys at most this many days.
  #
  # PROPORTIONAL and not a binary "readers > 1 lifts the cap", which is what this was first
  # written as and is defeated by one extra read: v2 mints a key per dispatch and a caller
  # can mint a child dispatch inside its own subtree, so a second principal costs a loop
  # nothing, and the documented MCP config already ships two keys. Under `cap * readers` that
  # second key buys 10 days rather than 30, a sixth is needed to reach saturation, and the
  # cost of gaming scales linearly with identities instead of being paid once. It also stops
  # the inversion the binary form had: a single-key fleet (the shape `heat_counts_query/5`'s
  # own comment describes) was the ONLY deployment that kept a cap at all.
  #
  # 5 rather than a rounder number: `importance_signal/1` puts 5 days at `log(6)/log(31)` =
  # 0.52, so one principal acting alone can reach just over HALF the band and no more, while
  # the 1-3-day population the curve is shaped for is untouched. A single-key tenant
  # therefore keeps a working prior at a compressed top — 1 through 5 days still order
  # normally and everything above 5 ties — which is the trade this bound makes deliberately.
  @solo_reader_day_cap 5

  @typedoc """
  The per-run tally. `gate` is `:open` on a run that read the events table.

  `measured` and `stamped` answer DIFFERENT questions and neither substitutes for the other.
  `measured` is how many of this tenant's OWN articles this run measured a read for and will
  therefore write — the usage number, and never more than the run's article cap. `stamped` is
  how many rows the write actually CHANGED, which `set_count/2`'s `IS DISTINCT FROM`
  predicate deliberately restricts to values that moved, so a steady-state night over an
  actively-read corpus reports `measured > 0` with `stamped: 0`. Reading `stamped` as "how
  much was read" turns exactly that healthy night into a corpus nobody opened.

  `measured` SATURATES at the cap, and `truncated` is what says so: on a truncated run the
  window found MORE read articles than this number and `measured` is the cap, not the count.
  Size a cap raise from the fact of truncation, never from this field — a run cannot report a
  total it deliberately stopped counting (`limit: cap + 1`). Reads of a SYSTEM CANONICAL are
  excluded from it, because the write predicate cannot reach that row either; the two numbers
  are drawn from the same population on purpose.
  """
  @type tally :: %{
          measured: non_neg_integer(),
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
    * `:max_articles` — the per-run article cap (default: `max_stamped_articles/0`). It
      exists so the truncation branch is reachable without seeding #{@max_stamped_articles}
      read articles, and so an operator running the stamp by hand on a degraded box can bound
      it.

      It does NOT bound only the run's work, and an operator has to know that before using
      it: the kept set is also what the CLEAR statement spares, so a bounded run sets
      `read_day_count` to NULL on every article of this tenant that it did not keep. On a
      tenant with 5,000 read articles, `max_articles: 100` clears the other 4,900 to neutral.
      Nothing is destroyed and nothing is demoted below neutral — the next unbounded run
      rebuilds all of it — but the tenant ranks without a usage signal until then. Pass a
      bound only when a full run is what you are trying to avoid.
  """
  @spec stamp(Ecto.UUID.t(), keyword()) :: tally()
  def stamp(tenant_id, opts \\ []) when is_binary(tenant_id) do
    since = window_start(opts)
    cap = article_cap(opts)

    case measure(tenant_id, since, cap) do
      {:ok, measured} -> write(tenant_id, measured, cap)
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

  @doc """
  The most distinct days ONE principal can contribute to an article's count.

  Public for the same single-source reason as `window_days/0` — the tests assert the bound
  rather than a copy of the number.
  """
  @spec solo_reader_day_cap() :: pos_integer()
  def solo_reader_day_cap, do: @solo_reader_day_cap

  # --- measurement -----------------------------------------------------------

  defp measure(tenant_id, since, cap) do
    query = read_days_query(tenant_id, since, cap)

    case HeavyRead.all(tenant_id, query, heavy_opts()) do
      {:error, :heavy_read_overloaded} -> {:error, :heavy_read_overloaded}
      rows when is_list(rows) -> {:ok, rows}
    end
  rescue
    e -> scan_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> scan_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  # Aggregate over the EVENTS, with two joins and no article column in the group key or the
  # select, so the read stays on the events index:
  #
  #   * `api_keys`, LEFT, ONLY to resolve the reader identity the per-principal cap needs. A
  #     key this tenant cannot see falls back to the key id rather than dropping the event.
  #   * `articles`, INNER, ONLY to drop events naming a row the WRITE could never stamp. An
  #     event carries the READING tenant's `tenant_id` and the read article's id, so a tenant
  #     reading the shared canon produces events for rows whose own `tenant_id` is NULL.
  #     Without this join those rows consumed slots in the per-run cap that stampable rows
  #     needed, and inflated `measured` by a number no `stamped` could ever match — an
  #     operator reading the audit event saw a permanent unexplained gap and would diagnose
  #     failed writes that never happened. This is the SAME predicate the two write
  #     statements carry, so `measured` now counts exactly the rows a write can reach.
  #
  # Both joins' `tenant_id` equalities are conjunctive, the shape `HeavyRead.guard!/2`
  # requires and the one `heat_counts_query/5` already runs through this gate.
  #
  # The day is cut in UTC EXPLICITLY, exactly as `heat_counts_query/5` does it: a bare
  # `::date` cast resolves in the connection's `TimeZone` GUC, so on a backend whose session
  # timezone is not UTC this would count days on a boundary the UTC-snapped window does not
  # use — the same value measured against two different calendars.
  #
  # `least(days, @solo_reader_day_cap * readers)` is the whole of the cap: each distinct
  # principal buys at most the cap in days, and the value can never exceed the article's
  # actual distinct-day count. The signal stays DISTINCT DAYS — `least` only ever lowers the
  # day count, so this never sums reader-days, which would let three readers on one day
  # outscore one reader on three.
  #
  # Ordered by the CAPPED value desc, raw days as the tiebreak, then id: the kept set has to
  # be selected by the number the ranking actually reads, or a run at the cap drops an article
  # with the higher final signal in favour of one whose raw count is inflated by a single
  # principal. Raw days second keeps the order deterministic between runs where the capped
  # values tie.
  defp read_days_query(tenant_id, since, cap) do
    counted =
      from(e in ArticleAccessEvent,
        left_join: k in ApiKey,
        on: k.id == e.api_key_id and k.tenant_id == ^tenant_id,
        inner_join: a in Article,
        on: a.id == e.article_id and a.tenant_id == ^tenant_id,
        where: e.tenant_id == ^tenant_id,
        where: e.access_type in ^Knowledge.heat_read_access_types(),
        where: e.accessed_at >= ^since,
        group_by: e.article_id,
        select: %{
          article_id: e.article_id,
          days: count(fragment("((? at time zone 'UTC'))::date", e.accessed_at), :distinct),
          readers: count(fragment("coalesce(?, ?)", k.agent_id, e.api_key_id), :distinct)
        }
      )

    from(c in subquery(counted),
      order_by: [
        desc: fragment("least(?, ? * ?)", c.days, ^@solo_reader_day_cap, c.readers),
        desc: c.days,
        asc: c.article_id
      ],
      limit: ^(cap + 1),
      select: %{
        article_id: c.article_id,
        read_days: fragment("least(?, ? * ?)", c.days, ^@solo_reader_day_cap, c.readers)
      }
    )
  end

  # --- writes ----------------------------------------------------------------

  # The statements are NOT one transaction (by design — see `write_failed/2`), so a failure
  # part-way through leaves rows written. The tally therefore ACCUMULATES: it carries the
  # counts of the statements that committed and flips only the gate, because reporting
  # `stamped: 0` alongside a log line that says the corpus may be partially stamped is an
  # audit record that contradicts itself and the database.
  defp write(tenant_id, measured, cap) do
    truncated = length(measured) > cap
    kept = Enum.take(measured, cap)

    log_truncation(tenant_id, truncated, cap)

    acc = %{tally(:open) | truncated: truncated, measured: length(kept)}

    case set_counts(tenant_id, group_by_days(kept), acc) do
      {:ok, acc} -> clear_step(tenant_id, Enum.map(kept, & &1.article_id), acc)
      {:error, acc} -> acc
    end
  end

  defp set_counts(tenant_id, groups, acc) do
    Enum.reduce_while(groups, {:ok, acc}, &set_one(tenant_id, &1, &2))
  end

  defp set_one(tenant_id, group, {:ok, acc}) do
    case guarded(tenant_id, fn -> set_count(tenant_id, group) end) do
      {:ok, written} -> {:cont, {:ok, %{acc | stamped: acc.stamped + written}}}
      :error -> {:halt, {:error, %{acc | gate: :write_failed}}}
    end
  end

  defp clear_step(tenant_id, ids, acc) do
    case guarded(tenant_id, fn -> clear_absent(tenant_id, ids) end) do
      {:ok, cleared} -> %{acc | cleared: cleared}
      :error -> %{acc | gate: :write_failed}
    end
  end

  defp guarded(tenant_id, fun) do
    {:ok, fun.()}
  rescue
    e ->
      write_failed(tenant_id, ExitTag.tag(e))
      :error
  catch
    :exit, reason ->
      write_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
      :error
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
    %{measured: 0, stamped: 0, cleared: 0, truncated: false, gate: gate}
  end

  defp article_cap(opts) do
    case Keyword.get(opts, :max_articles) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> @max_stamped_articles
    end
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
        "not one transaction). Both are idempotent, so the next run reconciles it. The " <>
        "tally's counts are what committed before the failure, not zero."
    )

    :ok
  end

  defp log_truncation(_tenant_id, false, _cap), do: :ok

  # Names the SOURCE of the effective cap, not `@max_stamped_articles` unconditionally: on an
  # operator's `max_articles:` run the module attribute was not in force, so telling them to
  # raise it is a remedy for a run they did not make.
  defp log_truncation(tenant_id, true, cap) do
    source =
      if cap == @max_stamped_articles,
        do: "raise @max_stamped_articles if this is steady state",
        else: "this run passed :max_articles, so the bound is the caller's, not the module's"

    Logger.warning(
      "Knowledge.Importance: tenant=#{tenant_id} read more than #{cap} " <>
        "distinct articles in the window; the least-used tail is cleared to neutral rather " <>
        "than stamped, and it is the SAME tail every night until the cap is raised (" <>
        source <> ")."
    )
  end
end
