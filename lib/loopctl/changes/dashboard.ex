defmodule Loopctl.Changes.Dashboard do
  @moduledoc """
  The reads behind the chg dashboard (US-50.5, `LoopctlWeb.ChgLive`): one function per panel,
  each answering one of the 2026-10-28 audit questions from the ledger rows fleet machines
  deliver (`Loopctl.Changes.Ledger`), the merged-PR review outcomes
  (`Loopctl.Changes.PrReviewOutcomes`) and the change cursors the reconcile sweep flags
  (`Loopctl.Changes.Reconcile`).

  ## How it reads

  Every query runs on `Loopctl.HeavyReadRepo` through `Loopctl.HeavyRead`, whose guard refuses
  any query with a base table not pinned to the caller's `tenant_id`: these are aggregations an
  operator can re-run at will, and the authenticated pool is not where they belong. A shed read
  (`{:error, :heavy_read_overloaded}`) makes that one panel `:unavailable`; the other panels
  still render.

  ## Filters

  `filters` is `%{repo: String.t() | nil, host: String.t() | nil, since: DateTime.t()}`. `repo`
  is matched case-insensitively (`Loopctl.Changes.Events.repo_key/1`). `host` narrows the panels
  whose rows carry a host (the ledger rows); review outcomes and change cursors have none, and
  ignore it. `since` bounds every panel by its own time column.

  ## What the fields mean

  The ledger row shape is chg's (`chg/cli/src/shadow.rs`, `Row`). `raw` is UNTRUSTED text from
  a fleet machine: it is cast only by guarded fragments, so a malformed value counts as absent
  and never fails a read.

  - A `chg` row is a shadow check, a `gate` row the authoritative gate. Verdicts are
    `pass | fail | error | skipped`.
  - A FALLBACK is a `chg` row with `mode = "all"`: selection widened to the whole suite. Its
    reason is the row's `selection` text.
  - SELECTION QUALITY is read on `chg` rows that selected (`mode` present and not `all`): the
    size of `selected` against the row's `floor` when it carries one. A MISS is a `chg` row that
    passed on a commit whose `gate` row failed: the selection left out a test that mattered.
  - Phase times are the `chg` row's `hydrate_ms`, `static_ms`, `affected_ms` and `tests_ms`, and
    `lock_wait_ms` on rows that carry it.
  """

  import Ecto.Query

  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Changes.PrReviewOutcomes
  alias Loopctl.HeavyRead

  # A non-negative integer field of `raw`, or NULL when it is absent or not a plain decimal of
  # at most 15 digits (so the cast can never fail the read).
  defmacrop json_int(raw, key) do
    quote do
      fragment(
        "CASE WHEN (?->>?) ~ '^[0-9]{1,15}$' THEN (?->>?)::bigint END",
        unquote(raw),
        unquote(key),
        unquote(raw),
        unquote(key)
      )
    end
  end

  # A text field of `raw`, cut to 200 characters; NULL when absent.
  defmacrop json_text(raw, key) do
    quote do
      fragment("left(?->>?, 200)", unquote(raw), unquote(key))
    end
  end

  # How many tests `raw.selected` lists, or NULL when it is not an array.
  defmacrop selected_count(raw) do
    quote do
      fragment(
        "CASE WHEN jsonb_typeof(?->'selected') = 'array' THEN jsonb_array_length(?->'selected') END",
        unquote(raw),
        unquote(raw)
      )
    end
  end

  @verdicts ~w(pass fail error skipped)
  @phases ~w(hydrate_ms static_ms affected_ms tests_ms lock_wait_ms)
  @list_limit 50

  @typedoc "The dashboard's filters; see the moduledoc."
  @type filters :: %{
          optional(:repo) => String.t() | nil,
          optional(:host) => String.t() | nil,
          required(:since) => DateTime.t()
        }

  @typedoc "A panel's data, or `:unavailable` when its read was shed."
  @type panel(data) :: data | :unavailable

  @doc "The verdicts a gate outcome is counted under, in display order."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "The phase-time fields read from `raw`, in display order."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "How many rows a list panel shows at most."
  @spec list_limit() :: pos_integer()
  def list_limit, do: @list_limit

  @doc """
  The repos and hosts the filters can name: those of ledger rows since `since`, plus the repos
  of review outcomes merged since then. Sorted; at most `list_limit/0` of each.
  """
  @spec options(Ecto.UUID.t(), DateTime.t()) :: %{repos: [String.t()], hosts: [String.t()]}
  def options(tenant_id, %DateTime{} = since) do
    ledger = from(r in LedgerRow, where: r.tenant_id == ^tenant_id and r.at >= ^since)

    repos =
      read_all(tenant_id, ledger |> distinct(true) |> select([r], r.repo), []) ++
        read_all(
          tenant_id,
          from(o in Loopctl.Changes.PrReviewOutcome,
            where: o.tenant_id == ^tenant_id and o.merged_at >= ^since,
            distinct: true,
            select: o.repo
          ),
          []
        )

    hosts = read_all(tenant_id, ledger |> distinct(true) |> select([r], r.host), [])

    %{repos: bounded_sort(repos), hosts: bounded_sort(hosts)}
  end

  defp bounded_sort(values), do: values |> Enum.uniq() |> Enum.sort() |> Enum.take(@list_limit)

  @doc """
  Gate outcomes over time: per UTC day, per kind (`chg`, `gate`), the count of each verdict.
  Newest day first. Each entry: `%{day: Date.t(), kind: String.t(), counts: %{verdict => n},
  total: n}`.
  """
  @spec gate_outcomes(Ecto.UUID.t(), filters()) :: panel([map()])
  def gate_outcomes(tenant_id, filters) do
    query =
      from r in ledger(tenant_id, filters),
        where: r.kind in ["chg", "gate"],
        group_by: [fragment("(?::date)", r.at), r.kind, r.verdict],
        select: {fragment("(?::date)", r.at), r.kind, r.verdict, count(r.id)}

    with rows when is_list(rows) <- read(tenant_id, query) do
      rows
      |> Enum.group_by(fn {day, kind, _v, _n} -> {day, kind} end)
      |> Enum.map(&day_entry/1)
      |> Enum.sort_by(&{-Date.to_gregorian_days(&1.day), &1.kind})
    end
  end

  defp day_entry({{day, kind}, group}) do
    counts = Map.new(group, fn {_d, _k, verdict, n} -> {verdict || "none", n} end)
    %{day: day, kind: kind, counts: counts, total: Enum.sum(Map.values(counts))}
  end

  @doc """
  The fallback rate: of the `chg` rows in range, how many ran `mode = "all"`, and the most
  common reasons (`selection`) they gave. `%{checks: n, fallbacks: n, rate: float | nil,
  reasons: [%{reason: String.t(), count: n}]}`.
  """
  @spec fallbacks(Ecto.UUID.t(), filters()) :: panel(map())
  def fallbacks(tenant_id, filters) do
    chg = from(r in ledger(tenant_id, filters), where: r.kind == "chg")

    totals =
      from r in chg,
        select: {
          count(r.id),
          filter(count(r.id), fragment("(?->>'mode') = 'all'", r.raw))
        }

    reasons =
      from r in chg,
        where: fragment("(?->>'mode') = 'all'", r.raw),
        group_by: fragment("coalesce(?->>'selection', '')", r.raw),
        select: {fragment("coalesce(?->>'selection', '')", r.raw), count(r.id)},
        order_by: [desc: count(r.id)],
        limit: 8

    with {checks, fallbacks} <- read_one(tenant_id, totals),
         rows when is_list(rows) <- read(tenant_id, reasons) do
      %{
        checks: checks,
        fallbacks: fallbacks,
        rate: if(checks > 0, do: fallbacks / checks),
        reasons: Enum.map(rows, fn {reason, n} -> %{reason: reason, count: n} end)
      }
    end
  end

  @doc """
  Selection quality on `chg` rows that selected: how many, the mean and largest number of tests
  selected, the mean `floor` on rows that carry one, and the misses (a passing `chg` row on a
  commit whose `gate` row failed), newest first. `%{checks: n, mean_selected: float | nil,
  max_selected: n | nil, mean_floor: float | nil, misses: [%{repo, host, sha, at}]}`.
  """
  @spec selection(Ecto.UUID.t(), filters()) :: panel(map())
  def selection(tenant_id, filters) do
    selecting =
      from r in ledger(tenant_id, filters),
        where: r.kind == "chg",
        where: fragment("(?->>'mode') IS NOT NULL AND (?->>'mode') <> 'all'", r.raw, r.raw)

    stats =
      from r in selecting,
        select: {
          count(r.id),
          avg(selected_count(r.raw)),
          max(selected_count(r.raw)),
          avg(json_int(r.raw, "floor"))
        }

    misses =
      from r in ledger(tenant_id, filters),
        join: g in LedgerRow,
        on:
          g.tenant_id == ^tenant_id and g.repo == r.repo and g.sha == r.sha and g.kind == "gate" and
            g.verdict == "fail",
        where: r.kind == "chg" and r.verdict == "pass",
        distinct: [desc: r.at, asc: r.id],
        order_by: [desc: r.at, asc: r.id],
        limit: @list_limit,
        select: %{id: r.id, repo: r.repo, host: r.host, sha: r.sha, at: r.at}

    with {checks, mean_selected, max_selected, mean_floor} <- read_one(tenant_id, stats),
         rows when is_list(rows) <- read(tenant_id, misses) do
      %{
        checks: checks,
        mean_selected: to_float(mean_selected),
        max_selected: max_selected,
        mean_floor: to_float(mean_floor),
        misses: rows
      }
    end
  end

  @doc """
  Time per gate phase on `chg` rows: for each of `phases/0`, how many rows carry it, its mean
  and its largest value, in milliseconds. `[%{phase, rows, mean_ms, max_ms}]`.
  """
  @spec phase_times(Ecto.UUID.t(), filters()) :: panel([map()])
  def phase_times(tenant_id, filters) do
    chg = from(r in ledger(tenant_id, filters), where: r.kind == "chg")

    queries =
      Enum.map(@phases, fn phase ->
        {phase,
         from(r in chg,
           where: not is_nil(json_int(r.raw, ^phase)),
           select: {count(r.id), avg(json_int(r.raw, ^phase)), max(json_int(r.raw, ^phase))}
         )}
      end)

    Enum.reduce_while(queries, [], fn {phase, query}, acc ->
      case read_one(tenant_id, query) do
        {rows, mean, max} ->
          {:cont, [%{phase: phase, rows: rows, mean_ms: to_float(mean), max_ms: max} | acc]}

        :unavailable ->
          {:halt, :unavailable}
      end
    end)
    |> case do
      :unavailable -> :unavailable
      list -> Enum.reverse(list)
    end
  end

  @doc """
  Flaky tests: the newest `kind = "flaky"` rows, each with the test it names and its quarantine
  or issue reference. `[%{id, repo, host, at, test, quarantine, issue}]`.
  """
  @spec flaky(Ecto.UUID.t(), filters()) :: panel([map()])
  def flaky(tenant_id, filters) do
    query =
      from r in ledger(tenant_id, filters),
        where: r.kind == "flaky",
        order_by: [desc: r.at, asc: r.id],
        limit: @list_limit,
        select: %{
          id: r.id,
          repo: r.repo,
          host: r.host,
          at: r.at,
          test: json_text(r.raw, "test"),
          quarantine: json_text(r.raw, "quarantine"),
          issue: json_text(r.raw, "issue")
        }

    read(tenant_id, query)
  end

  @doc """
  Runner samples: the newest `kind = "runner"` rows. `raw` has no fixed shape for this kind, so
  each carries its scalar fields other than the common ones as `fields`, a sorted keyword list
  of strings. `[%{id, repo, host, at, ms, fields}]`.
  """
  @spec runner_samples(Ecto.UUID.t(), filters()) :: panel([map()])
  def runner_samples(tenant_id, filters) do
    query =
      from r in ledger(tenant_id, filters),
        where: r.kind == "runner",
        order_by: [desc: r.at, asc: r.id],
        limit: @list_limit,
        select: %{id: r.id, repo: r.repo, host: r.host, at: r.at, ms: r.ms, raw: r.raw}

    with rows when is_list(rows) <- read(tenant_id, query) do
      Enum.map(rows, fn row ->
        row |> Map.put(:fields, sample_fields(row.raw)) |> Map.delete(:raw)
      end)
    end
  end

  @common_fields ~w(v kind repo host at_ms sha verdict ms)

  defp sample_fields(raw) when is_map(raw) do
    raw
    |> Enum.reject(fn {k, _v} -> k in @common_fields end)
    |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) end)
    |> Enum.map(fn {k, v} -> {k, v |> to_string() |> String.slice(0, 120)} end)
    |> Enum.sort()
    |> Enum.take(8)
  end

  defp sample_fields(_raw), do: []

  @doc """
  Review outcomes per merged PR since `since` (`PrReviewOutcomes.list/2`), newest first, and the
  findings over all of them counted by severity and by disposition.
  `%{outcomes: [outcome], by_severity: %{severity => n}, by_disposition: %{disposition => n},
  without_round: n}`.
  """
  @spec review_outcomes(Ecto.UUID.t(), filters()) :: panel(map())
  def review_outcomes(tenant_id, filters) do
    opts = [since: filters.since, limit: @list_limit] ++ repo_opt(filters)

    case PrReviewOutcomes.list(tenant_id, opts) do
      {:error, :heavy_read_overloaded} ->
        :unavailable

      outcomes ->
        findings = Enum.flat_map(outcomes, & &1.findings)

        %{
          outcomes: outcomes,
          by_severity: Enum.frequencies_by(findings, &(&1["severity"] || "unrated")),
          by_disposition: Enum.frequencies_by(findings, &(&1["disposition"] || "none")),
          without_round: Enum.count(outcomes, & &1.merged_without_counted_round)
        }
    end
  end

  defp repo_opt(%{repo: repo}) when is_binary(repo) and repo != "", do: [repo: repo]
  defp repo_opt(_filters), do: []

  @doc """
  Changes the reconcile sweep flagged `gap` or `stale` and that are still flagged, newest flag
  first, each with its cursor. `[%{id, repo, change_id, attention, attention_at, applied_seq,
  last_event_at}]`. `host` does not apply; `since` bounds `attention_at`.
  """
  @spec attention(Ecto.UUID.t(), filters()) :: panel([map()])
  def attention(tenant_id, filters) do
    query =
      from c in Cursor,
        where: c.tenant_id == ^tenant_id and not is_nil(c.attention),
        where: c.attention_at >= ^filters.since,
        order_by: [desc: c.attention_at, asc: c.id],
        limit: @list_limit,
        select: %{
          id: c.id,
          repo: c.repo,
          change_id: c.change_id,
          attention: c.attention,
          attention_at: c.attention_at,
          applied_seq: c.applied_seq,
          last_event_at: c.last_event_at
        }

    query =
      case filters do
        %{repo: repo} when is_binary(repo) and repo != "" ->
          where(query, [c], c.repo == ^Events.repo_key(repo))

        _ ->
          query
      end

    read(tenant_id, query)
  end

  # The ledger rows the filters select. Every panel over ledger rows starts here.
  defp ledger(tenant_id, filters) do
    query = from(r in LedgerRow, where: r.tenant_id == ^tenant_id and r.at >= ^filters.since)

    query =
      case filters do
        %{repo: repo} when is_binary(repo) and repo != "" ->
          where(query, [r], r.repo == ^Events.repo_key(repo))

        _ ->
          query
      end

    case filters do
      %{host: host} when is_binary(host) and host != "" -> where(query, [r], r.host == ^host)
      _ -> query
    end
  end

  defp read(tenant_id, query) do
    case HeavyRead.all(tenant_id, query, read_opts()) do
      {:error, :heavy_read_overloaded} -> :unavailable
      rows -> rows
    end
  end

  defp read_all(tenant_id, query, fallback) do
    case read(tenant_id, query) do
      :unavailable -> fallback
      rows -> rows
    end
  end

  defp read_one(tenant_id, query) do
    case HeavyRead.one(tenant_id, query, read_opts()) do
      {:error, :heavy_read_overloaded} -> :unavailable
      row -> row
    end
  end

  defp read_opts, do: Keyword.put(HeavyRead.opts(:enumeration), :on_overload, :tag)

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end
