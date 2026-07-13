defmodule Loopctl.Telemetry.ObanStats do
  @moduledoc """
  Real `oban_jobs` reads for the US-34.1 observability poll.

  `oban_jobs` is a GLOBAL infra table — no `tenant_id`, no RLS policy (it is not a
  tenant schema) — so this goes through plain `Loopctl.Repo` with raw SQL, NEVER
  `Loopctl.HeavyRead` (which STRUCTURALLY REQUIRES a `tenant_id`-scoped query and would
  raise on a query with no tenant predicate at all).

  Every query runs under a per-call SERVER-SIDE `SET LOCAL statement_timeout`
  (config `:oban_metrics_query_timeout_ms`, default 5s) inside its own short
  transaction — never a connection-startup `:parameters` timeout, which Fly MPG's
  pgbouncer rejects with `08P01 unsupported startup parameter` (the same rationale
  `Loopctl.HeavyRead` documents). This keeps the poll from being able to saturate the
  RLS pool (AC-34.1.3) even if `oban_jobs` grows large or a query plan degrades.
  """

  @behaviour Loopctl.Telemetry.ObanStatsBehaviour

  @default_query_timeout_ms 5_000

  @impl true
  @spec job_state_counts() :: [
          {state :: String.t(), queue :: String.t(), count :: non_neg_integer()}
        ]
  def job_state_counts do
    with_statement_timeout(fn ->
      %Postgrex.Result{rows: rows} =
        Loopctl.Repo.query!(
          "SELECT state::text, queue, count(*) FROM oban_jobs GROUP BY state, queue"
        )

      Enum.map(rows, fn [state, queue, count] -> {state, queue, count} end)
    end)
  end

  @impl true
  @spec executing_orphan_count(pos_integer()) :: non_neg_integer()
  def executing_orphan_count(threshold_minutes)
      when is_integer(threshold_minutes) and threshold_minutes > 0 do
    # The cutoff is computed HERE, in Elixir, as a naive (no-tz) UTC timestamp, and
    # bound as a plain query parameter — NEVER `now() - interval` compared directly
    # against `attempted_at` in SQL. `oban_jobs.attempted_at` is a `timestamp without
    # time zone` column that Oban always stores as naive UTC; comparing it to a
    # `timestamptz` expression (what `now() - interval` produces) makes Postgres
    # convert one side through the SESSION timezone, which is NOT UTC in this deploy
    # (`America/Denver` observed) — silently shifting the comparison by several hours
    # and making a genuinely stale job read as "not stale". Binding a naive
    # `NaiveDateTime` parameter sidesteps timezone interpretation entirely: it's
    # compared wall-clock-to-wall-clock against the naive column, matching exactly
    # how Oban itself writes `attempted_at`.
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-threshold_minutes * 60, :second)
      |> DateTime.to_naive()

    with_statement_timeout(fn ->
      %Postgrex.Result{rows: [[count]]} =
        Loopctl.Repo.query!(
          "SELECT count(*) FROM oban_jobs WHERE state = 'executing' AND attempted_at < $1",
          [cutoff]
        )

      count
    end)
  end

  # Runs `fun` inside a short transaction that first issues `SET LOCAL
  # statement_timeout`, scoping the server-side timeout to THIS poll only (never
  # relaxing/tightening it for any other query on the shared Repo pool).
  defp with_statement_timeout(fun) do
    ms = query_timeout_ms()

    {:ok, result} =
      Loopctl.Repo.transaction(
        fn ->
          Loopctl.Repo.query!("SET LOCAL statement_timeout = #{ms}")
          fun.()
        end,
        timeout: ms + 1_000
      )

    result
  end

  defp query_timeout_ms do
    case Application.get_env(:loopctl, :oban_metrics_query_timeout_ms, @default_query_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_query_timeout_ms
    end
  end
end
