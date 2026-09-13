defmodule LoopctlWeb.RunnerChannel.MinInterval do
  @moduledoc """
  The per-event rate floor of `LoopctlWeb.RunnerChannel` (`status`, `trace`, `trace_cursor`):
  a message is admitted only when at least `min_ms` have passed since the last admitted one.

  Pure, and the clock is an argument, so the comparison is tested at fixed times rather than
  against the wall clock. The channel keeps each event's last admitted time in its assigns and
  passes `System.monotonic_time(:millisecond)`.

  `:never` stands for "nothing admitted yet" rather than 0, because monotonic time is negative
  on a fresh VM, so a 0 sentinel would refuse the first message.
  """

  @type last :: :never | integer()

  @doc "`:ok` when a message at `now` is at least `min_ms` after `last`."
  @spec check(last(), integer(), non_neg_integer()) :: :ok | {:error, :rate_limited}
  def check(:never, _now, _min_ms), do: :ok
  def check(last, now, min_ms) when now - last >= min_ms, do: :ok
  def check(_last, _now, _min_ms), do: {:error, :rate_limited}
end
