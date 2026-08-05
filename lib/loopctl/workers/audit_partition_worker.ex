defmodule Loopctl.Workers.AuditPartitionWorker do
  @moduledoc """
  Oban worker that manages audit_log partition lifecycle.

  Runs daily via the Oban Cron plugin. Performs two tasks:

  1. **Creates future partitions** — ensures partitions exist for the current
     month plus 3 months ahead, preventing insert failures.

  2. **Sweeps existing partitions** — drops those older than the configured retention
     period (default: 90 days) to prevent unbounded table growth, and re-stamps the
     autovacuum tuning on every partition it retains.

  Partition naming convention: `audit_log_yYYYYmMM`
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  require Logger

  alias Ecto.Adapters.SQL

  @default_retention_days 90
  @future_months 3

  # Every statement here is DDL, and `CREATE ... PARTITION OF`, `DROP TABLE` and
  # `ALTER TABLE ... SET (...)` all require OWNERSHIP of the relation — a grant is not
  # enough. AdminRepo is the repo whose role owns them: migrations run through it
  # (`Loopctl.Release.migrate/0`), so it created every partition and every table this touches.
  #
  # This is correctness against the DOCUMENTED split (`deploy/FLY_SECRETS.md`: `DATABASE_URL`
  # is the grants-only `loopctl_app`, `ADMIN_DATABASE_URL` the owner `loopctl_admin`), NOT a
  # repair of a live outage — measured 2026-08-04, the hosted deployment does not currently
  # run that split. Its `DATABASE_URL` connects as `loopctl`, `ADMIN_DATABASE_URL` is UNSET so
  # `config/runtime.exs` falls it back to the same URL, and the partitions are owned by
  # `loopctl` — so Repo did own them and the DDL was succeeding. Do not "simplify" this back
  # to Repo on the strength of that: the moment the documented split is actually deployed,
  # every statement below starts failing into the fail-soft warning and the tuning silently
  # stops being applied, which is exactly the undetected shape #579 was.
  @ddl_repo Loopctl.AdminRepo

  # Autovacuum tuning stamped onto every partition (#579). Append-only leaves accumulate
  # rather than churn, so the INSERT-driven trigger is the knob — the update-churn
  # `vacuum_scale_factor` would wait on dead tuples that never arrive. Kept in lockstep with
  # `20260804230000_tune_autovacuum_on_append_heavy_tables.exs`, which stamps the partitions
  # that already existed; a partitioned PARENT has no heap and rejects these params entirely.
  @analyze_scale_factor "0.05"
  @vacuum_insert_scale_factor "0.1"
  @reloptions [
    "autovacuum_analyze_scale_factor=#{@analyze_scale_factor}",
    "autovacuum_vacuum_insert_scale_factor=#{@vacuum_insert_scale_factor}"
  ]
  # The ALTER's SET list is DERIVED from the guard's expected set, never spelled out a second
  # time: a third reloption added to only one of them would leave the containment check
  # permanently unsatisfiable, and the worker would re-take the SHARE UPDATE EXCLUSIVE lock
  # on every retained partition every day — the exact lock the guard exists to avoid.
  @reloptions_sql Enum.join(@reloptions, ", ")

  @impl Oban.Worker
  def perform(_job) do
    create_future_partitions()
    sweep_existing_partitions()
    :ok
  end

  @doc """
  Idempotently ensure audit_log partitions exist for a window around the current month.

  `:back` months (default 0) and `:forward` months (default the worker's lookahead) —
  both inclusive of the current month. Exposed so non-Oban contexts can guarantee
  partitions without the full worker run (e.g. test-suite startup, where the DB only ran
  migrations — whose partition window is both frozen at migration time AND anchored to
  when the migration happened to run, so fixed-date test rows in a recent PAST month may
  land outside it. Tests pass `back:` to cover those.)
  """
  @spec ensure_partitions(keyword()) :: :ok
  def ensure_partitions(opts \\ []) do
    back = Keyword.get(opts, :back, 0)
    forward = Keyword.get(opts, :forward, @future_months)
    create_partitions(-back..forward)
    :ok
  end

  defp create_future_partitions, do: create_partitions(0..@future_months)

  defp create_partitions(offset_range) do
    now = DateTime.utc_now()

    for offset <- offset_range do
      {year, month} = month_offset(now.year, now.month, offset)
      {next_year, next_month} = month_offset(year, month, 1)

      partition_name = partition_name(year, month)
      from_date = "#{year}-#{pad(month)}-01"
      to_date = "#{next_year}-#{pad(next_month)}-01"

      # CREATE IF NOT EXISTS pattern — attempt create, ignore "already exists"
      sql = """
      CREATE TABLE IF NOT EXISTS #{partition_name} PARTITION OF audit_log
        FOR VALUES FROM ('#{from_date}') TO ('#{to_date}')
      """

      case SQL.query(@ddl_repo, sql, []) do
        {:ok, _} ->
          stamp_autovacuum(partition_name)

        {:error, %{postgres: %{code: :duplicate_table}}} ->
          stamp_autovacuum(partition_name)

        {:error, reason} ->
          Logger.warning("Failed to create partition #{partition_name}: #{inspect(reason)}")
      end
    end
  end

  # `CREATE TABLE ... PARTITION OF` does NOT inherit the parent's reloptions — and the parent
  # cannot carry storage autovacuum params at all (no heap). So every partition must be
  # stamped individually or it is created with the global defaults, which is how the whole
  # corpus went un-analyzed until #579.
  #
  # SELF-HEALING over the whole RETENTION window, not just the create window: stamped on the
  # duplicate_table branch, and again from the retention sweep, so a partition created before
  # this code existed, created untuned during a deploy window, or rebuilt by a copy-swap that
  # silently drops reloptions is repaired on the next run wherever it sits in the window.
  # Guarded on the reloptions being ABSENT rather than stamped unconditionally, because
  # `ALTER TABLE` takes a SHARE UPDATE EXCLUSIVE lock and would fight the very autovacuum it
  # is enabling.
  defp stamp_autovacuum(partition_name) do
    # Two statements rather than one `DO $$` block: a DO block takes no bind parameters
    # (`$1` inside it is procedural, not a placeholder), so the name would have to be
    # interpolated into the anonymous block anyway. This way the LOOKUP is parameterised and
    # only the ALTER interpolates. The name is never caller input: the create loop generates
    # it from a year/month integer pair via `partition_name/2`, and the retention sweep —
    # which passes a `pg_class.relname`, i.e. database data — only reaches here through the
    # anchored `~r/^audit_log_y\d{4}m\d{2}$/` filter in `sweep_existing_partitions/0`. Drop
    # that regex and this interpolation becomes an injection sink.
    #
    # `to_regclass` narrows the check to ONE relation, where the old `relname = $1` could
    # match same-named relations in several schemas; it resolves through the connection's
    # search_path, as the unqualified ALTER below does, but nothing in this code BINDS the
    # two statements to one session — they rely on a uniform search_path config. `<@`
    # requires BOTH reloptions: keying on the analyze factor alone would read a partition
    # that lost only `vacuum_insert` as tuned and never restore the insert-driven trigger.
    already_tuned =
      SQL.query(
        @ddl_repo,
        "SELECT 1 FROM pg_class WHERE oid = to_regclass($1) AND $2 <@ reloptions",
        [partition_name, @reloptions]
      )

    case already_tuned do
      {:ok, %{num_rows: 0}} -> apply_autovacuum_opts(partition_name)
      {:ok, _} -> :ok
      {:error, reason} -> log_tuning_failure(partition_name, reason)
    end
  end

  defp apply_autovacuum_opts(partition_name) do
    sql = "ALTER TABLE #{partition_name} SET (#{@reloptions_sql})"

    case SQL.query(@ddl_repo, sql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> log_tuning_failure(partition_name, reason)
    end
  end

  # Never fail partition creation over tuning — an untuned partition still accepts writes,
  # and the next run re-attempts the stamp.
  defp log_tuning_failure(partition_name, reason) do
    Logger.warning("Failed to tune partition #{partition_name}: #{inspect(reason)}")
  end

  defp sweep_existing_partitions do
    retention_days = Application.get_env(:loopctl, :audit_retention_days, @default_retention_days)
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)
    cutoff_year = cutoff.year
    cutoff_month = cutoff.month

    # Query pg_inherits for existing partition LEAVES. `relkind = 'r'` matches the migration
    # and the test helper: a sub-partitioned child ('p') has no heap and would reject the
    # ALTER the retained branch now issues.
    {:ok, %{rows: rows}} =
      SQL.query(
        @ddl_repo,
        """
        SELECT child.relname
        FROM pg_inherits
        JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
        JOIN pg_class child ON pg_inherits.inhrelid = child.oid
        WHERE parent.relname = 'audit_log' AND child.relkind = 'r'
        ORDER BY child.relname
        """,
        []
      )

    for [partition_name] <- rows,
        partition_name =~ ~r/^audit_log_y\d{4}m\d{2}$/ do
      case parse_partition_date(partition_name) do
        {year, month} when year < cutoff_year or (year == cutoff_year and month < cutoff_month) ->
          SQL.query(@ddl_repo, "DROP TABLE IF EXISTS #{partition_name}", [])

          Logger.info("AuditPartitionWorker dropped expired partition: #{partition_name}")

        # Retained: heal here, so the healing scope is the RETENTION window rather than the
        # create window. A past-month partition that lost its reloptions to a rebuild is
        # still read (audit history, STH verification) and is never revisited by the create
        # loop, which only walks the current month forward.
        _ ->
          stamp_autovacuum(partition_name)
      end
    end
  end

  defp parse_partition_date(name) do
    case Regex.run(~r/audit_log_y(\d{4})m(\d{2})/, name) do
      [_, year, month] -> {String.to_integer(year), String.to_integer(month)}
      _ -> nil
    end
  end

  defp month_offset(year, month, offset) do
    total = year * 12 + month - 1 + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp partition_name(year, month), do: "audit_log_y#{year}m#{pad(month)}"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
