defmodule Loopctl.Delivery.DispatchLease do
  @moduledoc """
  The lease a claim gets when it is taken FOR A RUNNER DISPATCH (#879, US-44.5).

  The global claim lease (`Loopctl.Progress.claim_lease_seconds/0`, 24 hours) is sized for a
  human-driven claimant that renews on its own schedule. A runner session is different: the
  runner stops it at `wall_clock_seconds` from when it ACCEPTED the dispatch, so a session
  killed early holds its story for most of a day under the global lease. Lowering the global
  value is wrong for every other claimant (#879 records it being built and removed), so
  `Loopctl.Delivery.Placement` claims with a per-claim CAP instead, set in two steps:

      at the claim (provisional):   cap = placed_at  + wall_clock_seconds + grace_seconds()
      at the runner's acceptance:   cap = replied_at + wall_clock_seconds + grace_seconds()

  The second is written by `Loopctl.Runners.DispatchLedger.record_reply/3` in the transaction
  that records the acceptance, only ever FORWARD and only on the claim that dispatch serves
  (its story at its `claim_epoch`). It is anchored where `Loopctl.Runners.Capacity` anchors
  its own bound on the session — `replied_at` plus the wall clock the push delivered — so the
  push, the worktree setup and anything else between placement and acceptance never eat into
  the session's time, and a RESUMED dispatch that carries a longer wall clock is covered by
  the clock it actually runs under.

  The claim-time value travels to the runner as `RunnerDispatch.deadline_at`: the EARLIEST
  the claim can end. The runner budgets its session from its own `wall_clock_seconds`; the
  claim is held until at least `replied_at + wall_clock_seconds + grace_seconds()`.

  ## The grace, and why boot refuses a small one

  `DISPATCH_LEASE_GRACE_SECONDS` (default 900) is how long the claim outlives the session's
  wall clock. It must be at least `Loopctl.Runners.Capacity.release_grace_seconds/0`:
  capacity presumes the session running until `replied_at + wall_clock_seconds` plus that
  grace, and the accepted cap is measured from the same `replied_at` with the same wall
  clock, so with this grace at least that one the claim is never released while capacity
  still presumes its session running. `validate!/0` is called by
  `Loopctl.Application.start/2`, so a smaller value stops the release from booting, and
  `grace_from_env!/1` refuses one that is set but not an integer.
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
  The lease cap for a dispatch anchored at `at` with `wall_clock_seconds`:
  `at + wall_clock_seconds + grace_seconds/0`. `at` is `placed_at` for the provisional cap a
  claim is taken with, and the runner's `replied_at` for the one its acceptance moves it to.
  """
  @spec cap(DateTime.t(), pos_integer()) :: DateTime.t()
  def cap(%DateTime{} = at, wall_clock_seconds)
      when is_integer(wall_clock_seconds) and wall_clock_seconds > 0 do
    DateTime.add(at, wall_clock_seconds + grace_seconds(), :second)
  end

  @doc """
  `DISPATCH_LEASE_GRACE_SECONDS` as `config/runtime.exs` reads it: `nil` when it is unset or
  blank (the default applies), the integer it names, or an `ArgumentError` naming the
  variable when it is set to anything else — `"15m"`, `"1800s"`, `"120.0"`. A typo in the
  one knob that decides when a placed claim ends is a refused boot, never a silent default.
  Any INTEGER is returned as given; `validate!/0` is what refuses one below the floor.
  """
  @spec grace_from_env!(String.t() | nil) :: integer() | nil
  def grace_from_env!(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {seconds, ""} ->
            seconds

          _ ->
            raise ArgumentError,
                  "DISPATCH_LEASE_GRACE_SECONDS is #{inspect(raw)}, which is not a whole " <>
                    "number of seconds. Set it to an integer of at least " <>
                    "#{Capacity.release_grace_seconds()}, or unset it for the default of " <>
                    "#{@default_grace_seconds}."
        end
    end
  end

  def grace_from_env!(nil), do: nil

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
              "Both are added to the same replied_at + wall_clock_seconds, so an accepted " <>
              "driver-placed claim would be released while capacity still presumes its " <>
              "session running, and the story could be placed again under a live session. " <>
              "Set it to at least #{floor}, or unset it for the default of " <>
              "#{@default_grace_seconds}."
    end
  end
end
