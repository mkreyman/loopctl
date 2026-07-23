defmodule Loopctl.Knowledge.StreamingExport.NoopBodyProbe do
  @moduledoc """
  Production `Loopctl.Knowledge.StreamingExport.BodyProbe`: observes nothing.

  The streaming producer must NOT retain article bodies — that is the entire property the
  bounded-memory gate protects — so the production probe is a no-op returning a shared,
  module-level fun (no per-export closure allocation).
  """

  @behaviour Loopctl.Knowledge.StreamingExport.BodyProbe

  @noop &__MODULE__.ignore/1

  @impl true
  def probe, do: @noop

  @doc false
  @spec ignore(binary() | nil) :: :ok
  def ignore(_body), do: :ok
end
