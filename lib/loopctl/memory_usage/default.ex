defmodule Loopctl.MemoryUsage.Default do
  @moduledoc """
  Default `Loopctl.MemoryUsage` impl: retained refc binaries + ETS buffer bytes.

  Catches O(N) article accumulation in the streaming-export producer (article
  bodies are off-heap refc binaries, invisible to `process_info(:memory)`).
  """

  @behaviour Loopctl.MemoryUsage

  @impl true
  def usage(pid, state_table) do
    refc_bytes = retained_refc_binary_bytes(pid)
    ets_bytes = :ets.info(state_table, :memory) * :erlang.system_info(:wordsize)
    refc_bytes + ets_bytes
  end

  # Sum the `size` field of each refc binary the process currently RETAINS. The
  # tuple shape is `{binary_id, byte_size, ref_count}`; summing `byte_size` gives the
  # process's live off-heap binary footprint.
  defp retained_refc_binary_bytes(pid) do
    case :erlang.process_info(pid, :binary) do
      {:binary, refs} -> Enum.reduce(refs, 0, fn ref, acc -> acc + elem(ref, 1) end)
      _ -> 0
    end
  end
end
