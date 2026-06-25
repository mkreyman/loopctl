defmodule Loopctl.Telemetry.MetricsReporter do
  @moduledoc """
  Fault-isolating wrapper for the Prometheus scrape reporter (US-27.15).

  The reporter (`TelemetryMetricsPrometheus`) starts an HTTP listener on an internal
  port (`:9568`) for Fly's managed-Prometheus scraper. An observability endpoint must
  NEVER be able to take down the API — but if the reporter were a DIRECT child of
  `LoopctlWeb.Telemetry`, a listener bind failure (`:eaddrinuse` — e.g. a fast in-place
  restart with the prior socket still in `TIME_WAIT`, or anything else holding the port)
  would crash that supervisor's `init`, and the failure could escalate through the two
  `one_for_one` supervisors (`LoopctlWeb.Telemetry` → `Loopctl.Supervisor`) and bring the
  whole app down over a metrics-only port (team review F1).

  So this GenServer owns the reporter's lifecycle OUT OF BAND. Its own `init/1` always
  succeeds (the reporter is started in `handle_continue/2`, after init returns), so it is
  a safe supervised child: a reporter start failure is logged and RETRIED on a timer
  rather than crashing the supervisor, and a crash of a started reporter is detected
  (trapped EXIT, since the reporter is started linked) and restarted out of band. Worst
  case is "no `/metrics` until the port frees" — the API is unaffected.
  """
  use GenServer

  require Logger

  # Backoff before re-attempting a failed reporter start (or restarting one that died).
  # A bind conflict (TIME_WAIT) typically clears well within this window.
  @retry_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # Trap exits so a death of the (linked) reporter arrives as a message we can handle
    # and retry, instead of propagating and killing this supervised wrapper.
    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, pid: nil}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, try_start(state)}

  @impl true
  def handle_info(:retry_start, state), do: {:noreply, try_start(state)}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    Logger.warning(
      "metrics reporter exited (#{inspect(reason)}); restarting out-of-band in #{@retry_ms}ms"
    )

    Process.send_after(self(), :retry_start, @retry_ms)
    {:noreply, %{state | pid: nil}}
  end

  # An EXIT from a now-stale reporter pid (we already moved on) or any other process.
  def handle_info(_msg, state), do: {:noreply, state}

  defp try_start(%{pid: pid} = state) when is_pid(pid), do: state

  defp try_start(%{opts: opts} = state) do
    case TelemetryMetricsPrometheus.start_link(opts) do
      {:ok, pid} ->
        Logger.info("metrics reporter started on internal /metrics port #{opts[:port]}")
        %{state | pid: pid}

      {:error, {:already_started, pid}} ->
        %{state | pid: pid}

      {:error, reason} ->
        Logger.warning(
          "metrics reporter failed to start (#{inspect(reason)}); retrying in #{@retry_ms}ms " <>
            "(the API is unaffected — only /metrics is degraded)"
        )

        Process.send_after(self(), :retry_start, @retry_ms)
        state
    end
  end
end
