defmodule Loopctl.Telemetry.SlowQueryLogger do
  @moduledoc """
  Logs queries slower than a configurable threshold, uniformly across every repo
  (US-27.4, AC-27.4.4/.5/.6).

  Rather than sprinkling timing at call sites, this attaches ONE `:telemetry`
  handler to the Ecto query event of all three repos (`[:loopctl, :repo, :query]`,
  `[:loopctl, :admin_repo, :query]`, `[:loopctl, :heavy_read_repo, :query]`). A
  query whose `total_time` exceeds `:slow_query_threshold_ms` (default 1000, tunable
  in config/env without a code change) is logged at `:warning` with `duration_ms`,
  the `repo`, the `source` table, and — when the query ran on the request process —
  the `tenant_id` and `request_id` from `Logger` metadata. A query under the
  threshold logs NOTHING (no per-query noise).

  ## Safety (AC-27.4.4 / disclosure)

  The raw SQL, bound parameters, and vector literals are NEVER logged — only the
  `source` table name and the duration. This mirrors `LoopctlWeb.DBErrorLogger`'s
  no-leak contract.
  """

  require Logger

  @handler_id __MODULE__
  @events [
    [:loopctl, :repo, :query],
    [:loopctl, :admin_repo, :query],
    [:loopctl, :heavy_read_repo, :query]
  ]

  @default_threshold_ms 1_000

  @doc """
  Attaches the slow-query handler. Idempotent: a duplicate attach (e.g. on a code
  reload) is ignored rather than raised.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the handler (used in focused tests)."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc "Configured slow-query threshold in milliseconds (default #{@default_threshold_ms})."
  @spec threshold_ms() :: non_neg_integer()
  def threshold_ms do
    Application.get_env(:loopctl, :slow_query_threshold_ms, @default_threshold_ms)
  end

  @doc false
  def handle_event(_event, measurements, metadata, _config) do
    total_native = Map.get(measurements, :total_time, 0)
    duration_ms = System.convert_time_unit(total_native, :native, :millisecond)

    if duration_ms >= threshold_ms() do
      log_slow(duration_ms, metadata)
    end

    :ok
  end

  defp log_slow(duration_ms, metadata) do
    repo = metadata[:repo]
    source = metadata[:source]
    meta = Logger.metadata()
    tenant_id = meta[:tenant_id]
    request_id = meta[:request_id]

    Logger.warning(
      "slow_query duration_ms=#{duration_ms} repo=#{inspect(repo)} source=#{source} " <>
        "tenant_id=#{tenant_id} request_id=#{request_id}",
      duration_ms: duration_ms,
      repo: inspect(repo),
      source: source,
      tenant_id: tenant_id,
      request_id: request_id
    )
  end
end
