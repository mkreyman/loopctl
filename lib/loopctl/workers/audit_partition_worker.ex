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

  @impl Oban.Worker
  def perform(_job) do
    create_future_partitions()
    drop_expired_partitions()
    :ok
  end

  defp create_future_partitions do
    now = DateTime.utc_now()

    for offset <- 0..@future_months do
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
          :ok

        {:error, %{postgres: %{code: :duplicate_table}}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to create partition #{partition_name}: #{inspect(reason)}")
      end
    end
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

    for [partition_name] <- rows do
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
