defmodule Loopctl.RateLimiter.FailOpenBackstop do
  @moduledoc """
  A pool-free, node-local counter that bounds admissions while the PRIMARY rate
  limiter is unconsultable (#564 review).

  ## Why this exists

  A capacity gate that meters its admissions is only bounded while its meter
  answers. `Loopctl.RateLimiter.Hammer` is node-local ETS, but every check goes
  through a **poolboy pool** — and `config/config.exs` documents, in its own
  comment, that a single-source flood can saturate that pool until a checkout
  times out and exits. The caller normalises that to "unconsultable" and, on a
  fail-OPEN gate, admits.

  That is the failure mode the ingest backlog gate exists to prevent, arriving by
  a second route: under a flood large enough to saturate `AdminRepo` (making the
  backlog UNMEASURABLE) *and* the limiter's own pool (making the allowance
  UNCONSULTABLE), admissions were bounded per request but unbounded across them —
  for exactly as long as the flood lasted.

  The gate already refuses to let its meter share a failure domain with the thing
  it measures (`fail_open_meter/1` pins away from the Postgres limiter for the
  same reason). This closes the remaining one: `:ets.update_counter/4` against a
  table this process owns takes no lock, no checkout, and no pool.

  ## What it is NOT

  A replacement for the primary limiter. It is consulted **only** when the
  primary could not answer, so it counts the unmetered period alone — a meter
  that fails mid-window starts the backstop from zero. That is deliberate: the
  job is to bound an outage, not to be exact across one. Being approximate in the
  admitting direction by less than one window is the acceptable error; being
  unbounded is not.

  Fixed windows are epoch-aligned, matching Hammer's bucketing, so a client
  advised to retry at the window boundary lands in a refilled window under either
  counter.

  If the table is unavailable (a caller running before the app tree is up), every
  function returns as if there were headroom rather than crashing a fail-open
  path — the same fallback posture as `Loopctl.RateLimiter.FailOpenLog`.
  """

  use GenServer

  @table :rate_limiter_fail_open_backstop

  # Sweep cadence for expired window rows. Generous: rows are tiny
  # ({bucket, window} -> integer) and a missed sweep costs memory, never
  # correctness, since the window is part of the key.
  @sweep_interval_ms 600_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @doc """
  Charge one token against `bucket` for the current `window_ms` window.

  Returns `:admitted` while the bucket is at or under `limit` for this window,
  `:exhausted` once it is over. Never raises, never exits.
  """
  @spec charge(String.t(), pos_integer(), pos_integer()) :: :admitted | :exhausted
  def charge(bucket, window_ms, limit), do: charge(bucket, window_ms, limit, @table)

  @doc """
  `charge/3` against an explicit table. Exists so the missing-table fallback is
  reachable from a test: the table is supervised, so in a running system there is
  no way to observe that branch, and an untested fallback on a fail-open path is
  how a "never crashes the caller" claim goes stale.
  """
  @spec charge(String.t(), pos_integer(), pos_integer(), atom()) :: :admitted | :exhausted
  def charge(bucket, window_ms, limit, table) do
    index = window_index(window_ms)
    key = {bucket, index}
    # The row carries its own ABSOLUTE expiry so the sweep never has to compare
    # window indices, which are only comparable between callers using the SAME
    # window width. `update_counter/4` touches position 2 only, so the expiry
    # keeps the value it was created with.
    expires_at = (index + 1) * window_ms

    case :ets.update_counter(table, key, {2, 1}, {key, 0, expires_at}) do
      count when count > limit -> :exhausted
      _count -> :admitted
    end
  rescue
    # ArgumentError when the table does not exist yet.
    ArgumentError -> :admitted
  end

  @doc """
  Drop every counter for `bucket`, across all windows. Test support.
  """
  @spec reset(String.t()) :: :ok
  def reset(bucket) do
    :ets.match_delete(@table, {{bucket, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", System.system_time(:millisecond)}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp window_index(window_ms), do: div(System.system_time(:millisecond), window_ms)
end
