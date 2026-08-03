defmodule Loopctl.Embeddings.LegacyRetirement do
  @moduledoc """
  The retirement TRIGGER for the US-41.1 legacy embedding columns (GH #551).

  After the side-table cutover flipped `embedding_side_table_reads` to `1`
  (2026-07-22), `articles.embedding` / `memories.embedding` stayed fully
  dual-written — correctly, because the column IS the revert
  (`Loopctl.Embeddings.SystemConfigReadPath`, AC-41.1.8(ii)/(iii)). What was missing
  was anything that ever ASKS whether the revert is still needed. At ~1.36 GB
  (HNSW + TOAST) that silence has a monthly price, and "retirement recorded as prose"
  is not a mechanism.

  This module is the mechanism. It does NOT drop anything — dropping stays a
  deliberate human migration. It decides, daily and from evidence, whether the drop
  is now OWED, and hands that verdict to
  `Loopctl.Workers.LegacyEmbeddingRetirementWorker` to raise.

  ## The two triggers

  A verdict of `:due` fires when the legacy columns still exist AND either:

    * **evidence** — `required_clear_days` consecutive UTC days of observations, all
      with `side_table_reads == 1` and no change in any legacy index's `idx_scan`
      counter. This is the "we can prove nothing reads it" path.

    * **deadline** — `review_by` has passed. This is the "we could not prove
      anything, and that is exactly when a retirement gets forgotten" path.

  The deadline is not a belt-and-braces flourish; it is what makes the whole thing
  fail closed. Every way the evidence path can go quiet — a probe that errors every
  run, a monitor nobody redeployed, an `idx_scan` that never settles because some
  forgotten query still touches the legacy index — looks IDENTICAL to "not due yet"
  from the outside. Without a date that fires on its own, an evidence-only check
  degrades silently into the very prose it replaced.

  ## Fail-closed, stated precisely

  "Fail closed" here means an inconclusive reading must never render as *already
  cleaned up* or *nothing to do*:

    * A probe that cannot read the catalog reports NO columns... which would read as
      retired. So `probe/0` returns `{:error, _}` as a whole rather than a partial map,
      and the worker treats that as a monitor failure (loud, retried) — never as a
      verdict. It reads `pg_attribute`, not `information_schema.columns`, for the same
      reason: the latter is privilege-FILTERED, so an under-privileged role gets zero
      rows and NO error — a silent `:retired` indistinguishable from a real one.
    * The LIVE `side_table_reads` reading vetoes both triggers while it is 0: the legacy
      column is then the active read path (the revert in progress), and the deadline
      degrades to `:deadline_blocked` rather than naming it for deletion.
    * A gap in the daily observations breaks the streak (`length(rows) == n` over a
      window of `n` distinct days is exactly the contiguity check, since
      `observed_on` is unique).
    * A `pg_stat_reset()` inside the window invalidates it: counters that went to
      zero are not counters that stayed still.
    * An index present at the end of the window but absent at its start invalidates
      it: an index created three days ago cannot testify about thirty.

  The one deliberately vacuous pass: if a legacy column survives with NO index over
  it, the scan check is trivially satisfied. That is a correct `:due`, not a hole —
  an unindexed legacy column is already past the expensive half of retirement (the
  655 MB HNSW is gone; only TOAST remains), and the read flag plus the streak still
  have to hold.

  ## Why counters need a table

  `pg_stat_user_indexes.idx_scan` is cumulative. "Zero scans over N days" is a delta,
  and a delta needs a stored earlier reading — hence
  `Loopctl.Embeddings.RetirementObservation`, one row per UTC day.

  Indexes are discovered BY COLUMN (every index whose key includes the legacy
  `embedding` attribute of `articles` / `memories`), never by name. The legacy index
  has already been renamed once in this repo's history
  (`20260624120000_reconcile_hnsw_index_name.exs`), and `memories` carries a PARTIAL
  one (`memories_live_embedding_hnsw_idx`) that a name list would have missed.
  """

  @behaviour Loopctl.Embeddings.LegacyRetirementBehaviour

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.RetirementObservation
  alias Loopctl.LocalGuc

  # The tables whose legacy `embedding` column this trigger is about. The side
  # tables (`article_embeddings` / `memory_embeddings`) are deliberately absent —
  # they are the REPLACEMENT, not the thing being retired.
  @legacy_tables ["articles", "memories"]
  @legacy_column "embedding"

  @default_required_clear_days 30

  # Six months after the read flag flipped to 1 (2026-07-22). Chosen so the question
  # resurfaces on its own well before the rollback value has decayed to zero but long
  # after any realistic need to exercise it. Overridable via config for tests and for
  # an operator who wants to pull it in.
  @default_review_by ~D[2027-01-22]

  @typedoc """
  A single live reading of the legacy footprint. Produced whole by `probe/0` — never
  partially, so a failed sub-query cannot masquerade as an absent column.
  """
  @type probe :: %{
          side_table_reads: integer(),
          legacy_columns: [String.t()],
          legacy_index_scans: %{optional(String.t()) => integer()},
          stats_reset_at: DateTime.t() | nil
        }

  @type verdict :: %{
          verdict: :due | :not_due | :retired,
          trigger: :evidence | :deadline | :deadline_blocked | nil,
          reasons: [String.t()],
          legacy_columns: [String.t()],
          clear_days: non_neg_integer(),
          required_clear_days: pos_integer(),
          review_by: Date.t(),
          deadline_passed?: boolean(),
          days_past_review_by: integer(),
          side_table_reads: integer(),
          legacy_index_scans: %{optional(String.t()) => integer()}
        }

  @doc "Consecutive clear days required before the evidence trigger fires."
  @spec required_clear_days() :: pos_integer()
  def required_clear_days, do: normalize_required(config()[:required_clear_days])

  # `||` only rejects nil/false, and BOTH degenerate values are truthy: `0` makes the
  # window empty, so every check passes over no rows and `:due` is asserted from no
  # evidence at all, and `1` makes `scan_defects/1` (which needs two readings for a
  # delta) return unconditionally — deleting the core of the evidence path. The
  # `pos_integer()` spec never enforced either, so the value is validated, not defaulted.
  defp normalize_required(value) when is_integer(value) and value >= 2, do: value
  defp normalize_required(nil), do: @default_required_clear_days

  defp normalize_required(value) do
    Logger.warning(
      "LegacyRetirement: required_clear_days #{inspect(value)} is not an integer >= 2; " <>
        "using #{@default_required_clear_days}"
    )

    @default_required_clear_days
  end

  @doc "The date past which retirement is owed regardless of what the evidence shows."
  @spec review_by() :: Date.t()
  def review_by, do: config()[:review_by] || @default_review_by

  defp config, do: Application.get_env(:loopctl, :embedding_legacy_retirement, [])

  # ---------------------------------------------------------------------------
  # Probe
  # ---------------------------------------------------------------------------

  @doc """
  Read the live legacy footprint: the read flag, which legacy columns survive, the
  cumulative scan counter of every index over them, and the statistics-reset stamp.

  Returns `{:error, reason}` as a WHOLE if any part is unreadable. A partial map is
  not offered on purpose: the caller's only safe reading of "I could not check" is
  "I still owe the check", and a map missing its `legacy_columns` key would instead
  read as a finished retirement.
  """
  @impl Loopctl.Embeddings.LegacyRetirementBehaviour
  @spec probe() :: {:ok, probe()} | {:error, term()}
  def probe do
    with {:ok, columns} <- legacy_columns(),
         {:ok, scans} <- legacy_index_scans(),
         {:ok, stats_reset_at} <- stats_reset_at() do
      {:ok,
       %{
         # Deliberately the INJECTED read path (`Embeddings.side_table_reads_enabled?/0`),
         # not a fresh `SystemConfig.get_int/2`: the question is what the request path
         # is actually doing, and re-deriving it from the underlying row would let the
         # two disagree at exactly the moment that disagreement matters.
         side_table_reads: if(Embeddings.side_table_reads_enabled?(), do: 1, else: 0),
         legacy_columns: columns,
         legacy_index_scans: scans,
         stats_reset_at: stats_reset_at
       }}
    end
  rescue
    error -> {:error, error}
  end

  # Read from `pg_attribute`/`pg_class`, NOT `information_schema.columns`: the latter is
  # privilege-FILTERED by design, so a role without privileges on these tables gets zero
  # rows and no error — indistinguishable from "the columns are gone", which `evaluate/2`
  # would turn straight into a silent `:retired`. Scoped to the whole search path
  # (`current_schemas(false)`) rather than `current_schema()`, for the reason
  # `ChannelPostRescanWorker`'s probes spell out: `current_schema()` is only the FIRST
  # entry, so a deployment whose search_path resolves elsewhere probes the wrong schema
  # and disables the trigger permanently.
  defp legacy_columns do
    sql = """
    SELECT c.relname
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = ANY(current_schemas(false))
      AND a.attname = $1
      AND c.relname = ANY($2)
      AND c.relkind = 'r'
      AND a.attnum > 0
      AND NOT a.attisdropped
    ORDER BY c.relname
    """

    case query(sql, [@legacy_column, @legacy_tables]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [name] -> name end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every index whose key includes the legacy `embedding` attribute of a legacy
  # table — discovered by COLUMN, not by name (see the moduledoc). `indkey` is an
  # int2vector of attribute numbers; a `0` entry marks an expression, which cannot
  # be this plain column and so is correctly never matched.
  defp legacy_index_scans do
    sql = """
    SELECT s.indexrelname, s.idx_scan
    FROM pg_stat_user_indexes s
    JOIN pg_index i ON i.indexrelid = s.indexrelid
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE s.schemaname = ANY(current_schemas(false))
      AND s.relname = ANY($1)
      AND a.attname = $2
    GROUP BY s.indexrelname, s.idx_scan
    ORDER BY s.indexrelname
    """

    case query(sql, [@legacy_tables, @legacy_column]) do
      {:ok, %{rows: rows}} ->
        {:ok, Map.new(rows, fn [name, scans] -> {name, scans || 0} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stats_reset_at do
    sql = "SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()"

    case query(sql, []) do
      {:ok, %{rows: [[reset]]}} -> {:ok, to_utc(reset)}
      {:ok, %{rows: _}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # A short statement_timeout keeps these catalog reads from ever pinning a connection in
  # AdminRepo's small (3-connection) pool — the US-27.11 starvation class. They are cheap
  # catalog/stat reads, so 5s is generous, not tight. Via `LocalGuc.timed_transaction/4`,
  # never a raw `SET LOCAL`: `SET LOCAL` is scoped to the TOP-LEVEL transaction, so a
  # nested one (every call under `Ecto.Adapters.SQL.Sandbox`) merges the 5s deadline into
  # the enclosing transaction on savepoint commit.
  defp query(sql, params) do
    LocalGuc.timed_transaction(AdminRepo, 5_000, fn ->
      case AdminRepo.query(sql, params) do
        {:ok, result} -> result
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp to_utc(_), do: nil

  # ---------------------------------------------------------------------------
  # Record
  # ---------------------------------------------------------------------------

  @doc """
  Upsert today's observation from a `t:probe/0`.

  One row per UTC day (`observed_on` is unique), so an Oban retry or a manual run
  refreshes the day rather than adding a second row for it — the streak is counted
  in days, and duplicates would let one day stand in for several.
  """
  @impl Loopctl.Embeddings.LegacyRetirementBehaviour
  @spec record(probe(), Keyword.t()) ::
          {:ok, RetirementObservation.t()} | {:error, Ecto.Changeset.t()}
  def record(probe, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    today = Keyword.get(opts, :today, DateTime.to_date(now))

    attrs = %{
      observed_on: today,
      observed_at: now,
      side_table_reads: probe.side_table_reads,
      legacy_columns_present: probe.legacy_columns,
      legacy_index_scans: probe.legacy_index_scans,
      stats_reset_at: probe.stats_reset_at
    }

    existing = AdminRepo.get_by(RetirementObservation, observed_on: today)

    (existing || %RetirementObservation{})
    |> RetirementObservation.changeset(attrs)
    |> AdminRepo.insert_or_update()
  end

  # ---------------------------------------------------------------------------
  # Evaluate
  # ---------------------------------------------------------------------------

  @doc """
  Decide whether the legacy columns are now owed a retirement.

  Takes the CURRENT `t:probe/0` explicitly rather than re-reading it, so the
  decision logic is exercisable without a live catalog and so one run's verdict is
  always about the same reading it recorded.

  Verdicts:

    * `:retired` — no legacy column survives. Nothing is owed; the trigger has been
      satisfied and this worker can be retired along with it.
    * `:due` — a legacy column survives AND (the evidence window is clear OR
      `review_by` has passed).
    * `:not_due` — a legacy column survives and neither trigger has fired.
  """
  @impl Loopctl.Embeddings.LegacyRetirementBehaviour
  @spec evaluate(probe(), Keyword.t()) :: verdict()
  def evaluate(probe, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    review_by = Keyword.get(opts, :review_by, review_by())

    required =
      case Keyword.fetch(opts, :required_clear_days) do
        {:ok, value} -> normalize_required(value)
        :error -> required_clear_days()
      end

    base = %{
      legacy_columns: probe.legacy_columns,
      required_clear_days: required,
      review_by: review_by,
      days_past_review_by: Date.diff(today, review_by),
      side_table_reads: probe.side_table_reads,
      legacy_index_scans: probe.legacy_index_scans
    }

    if probe.legacy_columns == [] do
      Map.merge(base, %{
        verdict: :retired,
        trigger: nil,
        reasons: ["no legacy embedding column remains"],
        clear_days: 0,
        deadline_passed?: false
      })
    else
      decide(base, today, required, review_by)
    end
  end

  @revert_reason "side_table_reads is currently 0 — the legacy column is the ACTIVE read path"

  # The LIVE reading vetoes BOTH triggers. The stored window can only speak for days
  # already past, so a revert flipped after the last observation is invisible to it — and
  # a revert is precisely what these columns are kept for. Firing `:due` then would name
  # the live read path for deletion, so the deadline degrades to `:deadline_blocked`
  # (still surfaced, never acted on) rather than to silence.
  defp decide(base, today, required, review_by) do
    {streak, window_reasons} = clear_streak(today, required)
    deadline_passed? = Date.compare(today, review_by) != :lt
    reverting? = base.side_table_reads != 1
    clear_days = if reverting?, do: 0, else: streak
    reasons = if reverting?, do: [@revert_reason | window_reasons], else: window_reasons

    {verdict, trigger, reasons} =
      cond do
        clear_days >= required ->
          {:due, :evidence,
           ["#{clear_days} consecutive clear day(s) at or above the #{required}-day bar"]}

        deadline_passed? and reverting? ->
          {:not_due, :deadline_blocked,
           [
             "review_by #{Date.to_iso8601(review_by)} has passed, but retirement is " <>
               "BLOCKED"
             | reasons
           ]}

        deadline_passed? ->
          {:due, :deadline, ["review_by #{Date.to_iso8601(review_by)} has passed" | reasons]}

        true ->
          {:not_due, nil, reasons}
      end

    Map.merge(base, %{
      verdict: verdict,
      trigger: trigger,
      reasons: reasons,
      clear_days: clear_days,
      deadline_passed?: deadline_passed?
    })
  end

  # Returns {clear_days, reasons_it_is_not_clear}. `clear_days` is `required` when the
  # whole window qualifies and 0 otherwise: this is a gate, not a progress bar, and
  # reporting a partial streak that a later check invalidates would be worse than
  # reporting none. The reasons are what an operator actually needs — WHY the window
  # is not clear.
  defp clear_streak(today, required) do
    case observations(Date.add(today, -(required - 1)), today) do
      {:ok, rows} ->
        reasons = window_defects(rows, required)
        if reasons == [], do: {required, []}, else: {0, reasons}

      {:error, tag} ->
        {0, ["the observation log is unreadable (#{tag}); there is no evidence window"]}
    end
  end

  # The log can be genuinely ABSENT — a crontab entry deployed ahead of its migration —
  # and unreadable must cost the EVIDENCE path without costing the deadline, which is the
  # one trigger designed to fire with no observations at all.
  defp observations(from_day, today) do
    {:ok,
     RetirementObservation
     |> where([o], o.observed_on >= ^from_day and o.observed_on <= ^today)
     |> order_by([o], asc: o.observed_on)
     |> AdminRepo.all()}
  rescue
    error -> {:error, inspect(error.__struct__)}
  end

  defp window_defects(rows, required) do
    # `observed_on` is unique, so "n rows inside an n-day window" IS contiguity.
    # A missing day is a day we cannot speak for, which is not the same as a quiet one.
    coverage =
      if length(rows) < required,
        do: ["only #{length(rows)} of #{required} day(s) observed"],
        else: []

    coverage ++ flag_defects(rows) ++ reset_defects(rows) ++ scan_defects(rows)
  end

  defp flag_defects(rows) do
    case Enum.filter(rows, &(&1.side_table_reads != 1)) do
      [] ->
        []

      off ->
        ["side_table_reads was not 1 on #{length(off)} day(s) in the window"]
    end
  end

  defp reset_defects([]), do: []

  defp reset_defects([first | _] = rows) do
    if Enum.all?(rows, &same_instant?(&1.stats_reset_at, first.stats_reset_at)) do
      []
    else
      ["pg_stat statistics were reset inside the window; scan deltas are meaningless"]
    end
  end

  defp same_instant?(nil, nil), do: true
  defp same_instant?(nil, _), do: false
  defp same_instant?(_, nil), do: false
  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  # Counters only ever increase (a reset is excluded above), so comparing each index's
  # window PEAK to its baseline is exactly "no scan happened in between". Every index seen
  # ANYWHERE in the window counts, not just at its endpoints: one created on day 5,
  # scanned hard, and dropped on day 25 appears at neither end, and an endpoint-only
  # comparison never examined it at all.
  defp scan_defects(rows) when length(rows) < 2, do: []

  defp scan_defects(rows) do
    first = scans(List.first(rows))
    seen = rows |> Enum.flat_map(&Map.keys(scans(&1))) |> Enum.uniq()

    missing = seen |> Enum.reject(&Map.has_key?(first, &1)) |> Enum.sort()

    scanned =
      for index <- seen -- missing,
          baseline = Map.get(first, index),
          is_integer(baseline),
          peak = peak_scans(rows, index, baseline),
          peak != baseline,
          do: "#{index} (+#{peak - baseline})"

    missing_reason =
      if missing == [],
        do: [],
        else: ["index(es) absent at the start of the window: #{Enum.join(missing, ", ")}"]

    scanned_reason =
      if scanned == [],
        do: [],
        else: [
          "legacy index scans inside the window: #{scanned |> Enum.sort() |> Enum.join(", ")}"
        ]

    missing_reason ++ scanned_reason
  end

  defp scans(row), do: row.legacy_index_scans || %{}

  defp peak_scans(rows, index, baseline) do
    rows
    |> Enum.map(&Map.get(scans(&1), index))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> baseline end)
  end
end
