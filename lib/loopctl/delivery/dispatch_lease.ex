defmodule Loopctl.Delivery.DispatchLease do
  @moduledoc """
  The lease a claim gets when it is taken FOR A RUNNER DISPATCH (#879, US-44.5).

  The global claim lease (`Loopctl.Progress.claim_lease_seconds/0`, 24 hours) is sized for a
  human-driven claimant that renews on its own schedule. A runner session is different: the
  runner hard-kills it at `wall_clock_seconds`, so a session killed early holds its story for
  most of a day under the global lease. Lowering the global value is wrong for every other
  claimant (#879 records it being built and removed), so `Loopctl.Delivery.Placement` claims
  with a per-claim CAP instead:

      cap = placed_at + wall_clock_seconds + grace_seconds()

  The same instant travels to the runner as `RunnerDispatch.deadline_at`, so the runner stops
  the session at the instant control may reclaim the story. That shared instant is what keeps
  a re-contracted story from running under two sessions: control places nothing before it,
  and a runner cut off from control keeps working only until it.

  ## The grace, and why boot refuses a small one

  `DISPATCH_LEASE_GRACE_SECONDS` (default 900) covers what runs BEFORE the runner's own
  wall clock starts — the push, the worktree setup — plus a renewal's round trip. It must be
  at least `Loopctl.Runners.Capacity.release_grace_seconds/0`: capacity presumes a slot busy
  until the wall clock plus that grace, and a claim released before capacity lets go of the
  slot would free the story while its session may still be running. `validate!/0` is called
  by `Loopctl.Application.start/2`, so such a value stops the release from booting rather
  than shipping a lease shorter than the session it guards.
  """

  alias Loopctl.Runners.Capacity

  @default_grace_seconds 900

  @doc """
  Seconds added past a dispatch's wall clock before its claim's lease cap:
  `:dispatch_lease_grace_seconds`, set from `DISPATCH_LEASE_GRACE_SECONDS`, default
  #{@default_grace_seconds}. Returned as configured — `validate!/0` is what refuses a bad one.
  """
  @spec grace_seconds() :: term()
  def grace_seconds,
    do: Application.get_env(:loopctl, :dispatch_lease_grace_seconds, @default_grace_seconds)

  @doc """
  The lease cap for a dispatch placed at `placed_at` with `wall_clock_seconds`:
  `placed_at + wall_clock_seconds + grace_seconds/0`.
  """
  @spec cap(DateTime.t(), pos_integer()) :: DateTime.t()
  def cap(%DateTime{} = placed_at, wall_clock_seconds)
      when is_integer(wall_clock_seconds) and wall_clock_seconds > 0 do
    DateTime.add(placed_at, wall_clock_seconds + grace_seconds(), :second)
  end

  @doc """
  Boot-time check of the configured grace. Raises `ArgumentError` naming both values when it
  is not an integer at least `Loopctl.Runners.Capacity.release_grace_seconds/0`.
  """
  @spec validate!() :: :ok
  def validate!, do: validate!(grace_seconds())

  @doc "`validate!/0` against an explicit grace, so the refusal is testable without config."
  @spec validate!(term()) :: :ok
  def validate!(grace) do
    floor = Capacity.release_grace_seconds()

    if is_integer(grace) and grace >= floor do
      :ok
    else
      raise ArgumentError,
            "DISPATCH_LEASE_GRACE_SECONDS is #{inspect(grace)}, below the runner capacity " <>
              "release grace of #{floor}s (Loopctl.Runners.Capacity.release_grace_seconds/0). " <>
              "A driver-placed claim would be released while capacity still presumes its " <>
              "session running, so the story could be placed again under a live session. " <>
              "Set it to at least #{floor}, or unset it for the default of " <>
              "#{@default_grace_seconds}."
    end
  end
end
