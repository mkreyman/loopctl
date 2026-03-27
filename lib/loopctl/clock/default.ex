defmodule Loopctl.Clock.Default do
  @moduledoc """
  Production clock implementation using system time.
  """

  @behaviour Loopctl.Clock.Behaviour

  @impl true
  def utc_now, do: DateTime.utc_now()
end
