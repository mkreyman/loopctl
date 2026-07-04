defmodule Loopctl.Knowledge.EmbeddingCircuitBreaker do
  @moduledoc """
  Stable, supervised OWNER of the ETS table backing the per-tenant embedding
  circuit breaker (review #2 follow-through).

  The breaker state lives in a `:public`, `:named_table` ETS table that
  `Loopctl.Knowledge` reads/writes directly with `:ets.update_counter` (atomic,
  lock-free) — so this process is NEVER on the hot path and can't bottleneck
  embedding throughput. It exists ONLY to own the table.

  ## Why a dedicated owner (the bug this fixes)

  An ETS table dies with the process that created it. If the table were created
  lazily by whatever transient process first touched the breaker — a web request, an
  Oban embedding job, or a `Task` spawned by `generate_embedding/3` — it would VANISH
  when that process finished: silently resetting every tenant's breaker, and, under
  concurrency, crashing a peer mid-`update_counter` with "table does not exist". A
  supervised owner keeps the table alive for the whole node lifetime; if this process
  ever crashes, the supervisor restarts it and `init/1` recreates the table (losing
  only the transient breaker counts, which is the correct fail-safe).

  Mirrors `Loopctl.Knowledge.ExportConcurrency` (the sibling ETS-owner in the tree).
  """

  use GenServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create + own the table here (in the GenServer process) so it persists for the
    # node's lifetime. Idempotent if it somehow already exists.
    :ok = Loopctl.Knowledge.init_circuit_breaker()
    {:ok, %{}}
  end
end
