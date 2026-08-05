defmodule Loopctl.Workers.AuditPartitionWorker do
  @moduledoc """
  Oban worker that manages audit_log partition lifecycle.

  Runs daily via the Oban Cron plugin. Performs two tasks:

  1. **Creates future partitions** — ensures partitions exist for the current
     month plus 3 months ahead, preventing insert failures.

  2. **Drops old partitions** — removes partitions older than the configured
     retention period (default: 90 days) to prevent unbounded table growth.

  Partition naming convention: `audit_log_yYYYYmMM`
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  require Logger

  alias Ecto.Adapters.SQL

  @default_retention_days 90
  @future_months 3

  # Autovacuum tuning stamped onto every partition (#579). Append-only leaves accumulate
  # rather than churn, so the INSERT-driven trigger is the knob — the update-churn
  # `vacuum_scale_factor` would wait on dead tuples that never arrive. Kept in lockstep with
  # `20260804230000_tune_autovacuum_on_append_heavy_tables.exs`, which stamps the partitions
  # that already existed; a partitioned PARENT has no heap and rejects these params entirely.
  @analyze_scale_factor "0.05"
  @vacuum_insert_scale_factor "0.1"

  @impl Oban.Worker
  def perform(_job) do
    create_future_partitions()
    drop_expired_partitions()
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

      case SQL.query(Loopctl.Repo, sql, []) do
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
  # SELF-HEALING, and stamped on the duplicate_table branch too: that covers a partition
  # created before this code existed, and one created untuned during a deploy window. Guarded
  # on the reloption being ABSENT rather than stamped unconditionally, because `ALTER TABLE`
  # takes a SHARE UPDATE EXCLUSIVE lock and would fight the very autovacuum it is enabling.
  defp stamp_autovacuum(partition_name) do
    # Two statements rather than one `DO $$` block: a DO block takes no bind parameters
    # (`$1` inside it is procedural, not a placeholder), so the name would have to be
    # interpolated into the anonymous block anyway. This way the LOOKUP is parameterised and
    # only the ALTER interpolates — and that name is generated from a year/month integer pair
    # by `partition_name/2`, never from caller input.
    already_tuned =
      SQL.query(
        Loopctl.Repo,
        "SELECT 1 FROM pg_class WHERE relname = $1 AND $2 = ANY(reloptions)",
        [partition_name, "autovacuum_analyze_scale_factor=#{@analyze_scale_factor}"]
      )

    case already_tuned do
      {:ok, %{num_rows: 0}} -> apply_autovacuum_opts(partition_name)
      {:ok, _} -> :ok
      {:error, reason} -> log_tuning_failure(partition_name, reason)
    end
  end

  defp apply_autovacuum_opts(partition_name) do
    sql = """
    ALTER TABLE #{partition_name} SET (
      autovacuum_analyze_scale_factor = #{@analyze_scale_factor},
      autovacuum_vacuum_insert_scale_factor = #{@vacuum_insert_scale_factor}
    )
    """

    case SQL.query(Loopctl.Repo, sql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> log_tuning_failure(partition_name, reason)
    end
  end

  # Never fail partition creation over tuning — an untuned partition still accepts writes,
  # and the next run re-attempts the stamp.
  defp log_tuning_failure(partition_name, reason) do
    Logger.warning("Failed to tune partition #{partition_name}: #{inspect(reason)}")
  end

  defp drop_expired_partitions do
    retention_days = Application.get_env(:loopctl, :audit_retention_days, @default_retention_days)
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)
    cutoff_year = cutoff.year
    cutoff_month = cutoff.month

    # Query pg_inherits for existing partition tables
    {:ok, %{rows: rows}} =
      SQL.query(
        Loopctl.Repo,
        """
        SELECT child.relname
        FROM pg_inherits
        JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
        JOIN pg_class child ON pg_inherits.inhrelid = child.oid
        WHERE parent.relname = 'audit_log'
        ORDER BY child.relname
        """,
        []
      )

    for [partition_name] <- rows,
        partition_name =~ ~r/^audit_log_y\d{4}m\d{2}$/ do
      case parse_partition_date(partition_name) do
        {year, month} when year < cutoff_year or (year == cutoff_year and month < cutoff_month) ->
          SQL.query(Loopctl.Repo, "DROP TABLE IF EXISTS #{partition_name}", [])

          Logger.info("AuditPartitionWorker dropped expired partition: #{partition_name}")

        _ ->
          :ok
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
