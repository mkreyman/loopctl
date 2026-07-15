defmodule Loopctl.ReplicaReadiness do
  @moduledoc """
  US-38.1 / AC-38.1.2 — fail-loud-at-boot readiness probe for the optional read replica.

  When an operator sets `REPLICA_DATABASE_URL` (a distinct read replica backing
  `Loopctl.HeavyReadRepo`), a MISconfigured/unreachable DSN must NOT let the app boot green
  and then 500 every heavy read at query time (semantic search, enumeration, export, change
  feed). A default supervised Ecto/Postgrex pool connects ASYNCHRONOUSLY and retries in the
  background, so `start_link` returns `{:ok, _}` even against an unreachable DSN — the pool
  never "fails loud" on its own.

  This module makes the documented "fail LOUD at boot" behaviour REAL. Called from
  `Loopctl.Application.start/2` (prod only), `assert_reachable!/0` probes the heavy-read pool
  with a trivial `SELECT 1` — with bounded retries to absorb a cold pool that is still
  establishing its first connection — and RAISES if the replica stays unreachable, aborting
  boot. It is a NO-OP unless a DISTINCT replica is configured
  (`Loopctl.DbCapacity.replica_configured?/0`), so today's default (no replica) is unchanged.

  The probe itself lives in `Loopctl.HeavyRead.probe/0` (the sole sanctioned toucher of the
  heavy-read pool) so this module never references `Loopctl.HeavyReadRepo` directly — which the
  build guard (`heavy_read_guard_test.exs`) forbids.
  """

  alias Loopctl.DbCapacity
  alias Loopctl.HeavyRead

  # Bounded retry budget: ~5s total, enough to let a cold pool warm up without mistaking a
  # still-connecting reachable replica for an unreachable one.
  @attempts 10
  @sleep_ms 500

  @doc """
  Assert the configured read replica is reachable, or RAISE (fail loud at boot).

  A NO-OP when no distinct replica is configured (`DbCapacity.replica_configured?/0` is
  `false`) — the default in dev/test and prod-without-replica. When a replica IS configured,
  probes the heavy-read pool and raises `RuntimeError` if it is unreachable after bounded
  retries.
  """
  @spec assert_reachable!() :: :ok
  def assert_reachable! do
    if DbCapacity.replica_configured?() do
      raise_if_unreachable!(probe(&default_probe/0, @attempts, @sleep_ms))
    else
      :ok
    end
  end

  @doc false
  # Decide-and-raise, split out so the raise path is unit-testable without an actually
  # unreachable DB.
  @spec raise_if_unreachable!(:ok | {:error, term()}) :: :ok
  def raise_if_unreachable!(:ok), do: :ok

  def raise_if_unreachable!({:error, reason}) do
    raise """
    REPLICA_DATABASE_URL is configured but Loopctl.HeavyReadRepo could not reach it at boot \
    (#{inspect(reason)}). Failing loud (AC-38.1.2) rather than booting green and 500-ing every \
    heavy read at query time. Verify the replica DSN/network/read-role, or UNSET \
    REPLICA_DATABASE_URL to fall back to the primary.\
    """
  end

  @doc false
  # Run `probe_fun` up to `attempts` times, sleeping `sleep_ms` between failures so a cold pool
  # still establishing its first connection isn't mistaken for an unreachable replica. Returns
  # the FIRST `:ok`, or the LAST `{:error, _}` once attempts are exhausted.
  @spec probe((-> :ok | {:error, term()}), pos_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def probe(probe_fun, attempts, sleep_ms) when is_function(probe_fun, 0) and attempts >= 1 do
    case probe_fun.() do
      :ok ->
        :ok

      {:error, _reason} when attempts > 1 ->
        Process.sleep(sleep_ms)
        probe(probe_fun, attempts - 1, sleep_ms)

      {:error, _reason} = err ->
        err
    end
  end

  # A trivial round-trip on the heavy-read pool (the replica when configured), via the
  # sanctioned wrapper so this module never touches HeavyReadRepo directly.
  defp default_probe, do: HeavyRead.probe()
end
