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
  rather than crashing the supervisor, and a crash of a started reporter is detected and
  restarted out of band. Worst case is "no `/metrics` until the port frees" — the API is
  unaffected.

  ## Failure-mode coverage (R2 adversarial review)

  The reporter start (ranch/cowboy under the hood) does NOT always return `{:error, _}`:
  on some OS conditions it RAISES or `exit`s. `try_start/1` therefore wraps the start in
  `try/rescue/catch` so a raise OR an exit funnels into the SAME logged + retried path as
  an `{:error, _}` — a start fault can never crash `handle_continue` and re-introduce the
  cascade this wrapper exists to prevent.

  A started reporter is tracked two ways depending on how it was acquired:

    * **`{:ok, pid}`** — the reporter is started LINKED (we trap exits), so its death
      arrives as an `{:EXIT, pid, reason}` message.
    * **`{:error, {:already_started, pid}}`** — a reporter someone else already started.
      We `Process.monitor/1` it (it is NOT linked to us), so its later death arrives as a
      `{:DOWN, ref, :process, pid, reason}` message. Without the monitor, that pid's
      death would go undetected and `/metrics` would stay dead with no retry —
      contradicting this module's guarantee (R2 review).

  Both death signals schedule the same out-of-band retry.
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

    # The reporter-start function is injectable (DEFAULT TelemetryMetricsPrometheus) so a
    # test can drive the prod-only isolation path (an `{:error, _}`-returning or RAISING
    # start) WITHOUT binding a real port. `opts` is otherwise passed straight through.
    {start_fun, opts} = Keyword.pop(opts, :start_fun, &TelemetryMetricsPrometheus.start_link/1)

    {:ok, %{opts: opts, start_fun: start_fun, pid: nil}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, try_start(state)}

  # `:retry_start` must remain SINGLE-FLIGHT: at most one retry may be in flight at a
  # time, or each failed attempt would schedule another and they would multiply. The
  # `is_pid(pid)` guard on `try_start/1` (a retry that finds the reporter already up is a
  # no-op) plus edge-scheduling (a retry is only ever scheduled from a failure/death
  # path, never speculatively) keep it single-flight. A future SECOND live caller of
  # `try_start` would break this invariant — keep `try_start` reachable only from
  # `handle_continue(:start, ...)` and the retry/death handlers.
  @impl true
  def handle_info(:retry_start, state), do: {:noreply, try_start(state)}

  # The linked `{:ok, pid}` reporter died.
  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    schedule_retry_after_death(reason)
    {:noreply, %{state | pid: nil}}
  end

  # The monitored `{:already_started, pid}` reporter died (it is NOT linked to us, so its
  # death arrives as a :DOWN, not an :EXIT). Same out-of-band retry as the linked case.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pid: pid} = state) do
    schedule_retry_after_death(reason)
    {:noreply, %{state | pid: nil}}
  end

  # An EXIT/DOWN from a now-stale reporter pid (we already moved on) or any other process.
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_retry_after_death(reason) do
    Logger.warning(
      "metrics reporter died (#{inspect(reason)}); restarting out-of-band in #{@retry_ms}ms"
    )

    Process.send_after(self(), :retry_start, @retry_ms)
  end

  defp try_start(%{pid: pid} = state) when is_pid(pid), do: state

  defp try_start(%{opts: opts, start_fun: start_fun} = state) do
    case safe_start(start_fun, opts) do
      {:ok, pid} ->
        Logger.info("metrics reporter started on internal /metrics port #{opts[:port]}")
        %{state | pid: pid}

      {:error, {:already_started, pid}} ->
        # We did NOT start (and are not linked to) this pid — monitor it so its later
        # death is detected and triggers the same out-of-band retry as a linked crash.
        Process.monitor(pid)
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

  # The reporter start (ranch/cowboy) can RETURN `{:error, _}`, RAISE, or `exit` depending
  # on the OS/port condition. Normalize all three into an `{:ok, pid}` / `{:error, reason}`
  # result so `try_start/1`'s single `case` covers every failure mode and a raise/exit can
  # never escape into `handle_continue` and crash this wrapper (R2 review).
  defp safe_start(start_fun, opts) do
    start_fun.(opts)
  rescue
    e -> {:error, {:raised, e}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
