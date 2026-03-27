defmodule Loopctl.Clock.Behaviour do
  @moduledoc """
  Behaviour for clock operations.

  Allows DI-based swapping for deterministic time in tests.
  """

  @callback utc_now() :: DateTime.t()
end
