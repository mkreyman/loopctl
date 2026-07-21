defmodule Loopctl.Embeddings.DisclosureCache do
  @moduledoc """
  US-41.1 (review) — a tiny, supervised, TTL'd ETS cache for the semantic-search
  DISCLOSURE meta (`system_corpus_*` + `reembed_*`).

  ## Why this exists

  `Loopctl.Knowledge.search_semantic/3` merges `Embeddings.system_corpus_meta/2` and
  `Embeddings.reembed_meta/2` into EVERY semantic response. In the STEADY state those
  are three round trips that always answer the same thing:

    * `system_corpus_meta/2` runs an anti-join over every `scope: :system` article
      with a per-row index probe into `article_embeddings`. Fully materialized, NO row
      qualifies — so the `LIMIT 1` short-circuit never fires and the cost grows
      linearly with loopctl's own canonical wiki corpus, on the hottest read in the
      product;
    * `reembed_meta/2` adds two more `exists?` probes.

  The answer only changes when the materialization worker runs, a system article is
  added/published, or a re-embed makes progress — none of which is request-driven.
  A short TTL therefore removes the per-request cost while bounding staleness to the
  TTL (a disclosure string, never a result-set predicate).

  ## The table is OWNED by this process

  An ETS table dies with its creator. Created lazily by a web request it would vanish
  when that request finished and crash a peer mid-lookup. This GenServer owns it for
  the node's lifetime — the same pattern as `Loopctl.Knowledge.EmbeddingCircuitBreaker`.

  ## Disabling

  `config :loopctl, :embedding_disclosure_cache_ms, 0` disables caching entirely
  (config-based DI — `config/test.exs` sets 0 so tests observe disclosure changes
  immediately, with no `Application.put_env` anywhere).
  """

  use GenServer

  @table :loopctl_embedding_disclosure_cache
  @default_ttl_ms 5_000
  @sweep_interval_ms 60_000

  # Cross-node invalidation bridge (review, findings 5/10). The ETS table is
  # `:named_table` (node-LOCAL) and Erlang clustering does NOT share ETS, so a pin
  # write on one node is invisible to peers until their TTL expires. On a multi-node
  # deployment (Fly) that left peers serving a STALE dimension/model pin for up to the
  # TTL after `complete_reembed/2` swept the old-dimension rows: peer query vectors
  # scanned a dimension whose rows were just deleted (empty recall, no keyword
  # fallback) and peer writes re-created rows the sweep removed. Broadcasting the
  # invalidation over `Phoenix.PubSub` busts every peer's node-local entry within a
  # message hop — mirroring `Loopctl.Llm.SettingsCache.invalidate_cluster/1`. The TTL
  # remains the bounded backstop if a broadcast is dropped (netsplit).
  @pubsub Loopctl.PubSub
  @invalidate_topic "embeddings:disclosure_cache:invalidate"

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = init_table()
    # Subscribe so a PEER node's invalidation broadcast busts THIS node's entry.
    # `Phoenix.PubSub` starts strictly before this owner in the supervision tree and
    # stays up across our restarts, so the subscribe is safe to do inline.
    Phoenix.PubSub.subscribe(@pubsub, @invalidate_topic)
    schedule_sweep()
    {:ok, %{}}
  end

  # Periodic eviction (review): reads check `expires_at` themselves, but nothing
  # deleted an expired row that is never looked up again, so the table retained a row
  # for every `{tenant, dimension}` ever searched for the node's lifetime. This is the
  # ETS-with-TTL house pattern (patterns-elixir-otp) — the read-side expiry check paired
  # with a periodic `select_delete` of everything already past `expires_at`.
  @impl true
  def handle_info(:sweep, state) do
    if :ets.whereis(@table) != :undefined do
      now = System.monotonic_time(:millisecond)
      # match {key, value, expires_at} where expires_at =< now
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    end

    schedule_sweep()
    {:noreply, state}
  end

  # A PEER node invalidated `key` (a pin write / re-embed completion there); bust our
  # node-local entry so we stop serving the stale dimension/model pin.
  def handle_info({:invalidate, key}, state) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:broadcast_invalidate, key}, state) do
    # Fan out to peer nodes, excluding self() (this node's subscriber is the owner
    # itself) so the originating node does not re-process its own invalidation.
    _ = Phoenix.PubSub.broadcast_from(@pubsub, self(), @invalidate_topic, {:invalidate, key})
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @doc false
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
      rescue
        ArgumentError -> :already_exists
      end
    end

    :ok
  end

  @doc "The cache TTL in milliseconds; `0` disables caching."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms, do: Application.get_env(:loopctl, :embedding_disclosure_cache_ms, @default_ttl_ms)

  @doc """
  Returns the cached value for `key`, or computes it with `fun`, caches it and
  returns it. With a `0` TTL `fun` is always called and nothing is stored.
  """
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, fun) when is_function(fun, 0) do
    case ttl_ms() do
      0 -> fun.()
      ttl -> cached_fetch(key, fun, ttl)
    end
  end

  @doc "Drops every cached entry (used by the operator levers that invalidate a disclosure)."
  @spec flush() :: :ok
  def flush do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Drops the single cached entry for `key` — used by the tenant-pin write paths so a
  re-embed completion (which moves the dimension/model pin) is observed immediately
  rather than after the TTL.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end

  @doc """
  Invalidates `key` on THIS node (see `invalidate/1`) AND broadcasts the invalidation
  to peer nodes over `Phoenix.PubSub` so their node-local ETS busts promptly.

  Used by the tenant-pin write paths (`Embeddings.invalidate_tenant_pin/1`) so a
  re-embed completion — which moves the dimension/model pin AND sweeps the old rows —
  is observed cluster-wide within a PubSub hop, not just on the node that handled the
  write. Without this, peer nodes served the stale pin for up to the TTL and scanned a
  swept dimension (empty recall) or re-created swept rows (findings 5/10). If the
  broadcast is dropped (netsplit) the bounded TTL still evicts the peer's stale entry.
  """
  @spec invalidate_cluster(term()) :: :ok
  def invalidate_cluster(key) do
    invalidate(key)
    # Broadcast off the (rare) write path via the owner so we can exclude THIS node's
    # subscriber from the fan-out (no self-echo). `GenServer.cast` is safe if the owner
    # is momentarily down mid-restart — the local invalidate already ran.
    GenServer.cast(__MODULE__, {:broadcast_invalidate, key})
    :ok
  end

  defp cached_fetch(key, fun, ttl) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        store(key, value, now + ttl)
        value
    end
  end

  defp lookup(key, now) do
    if :ets.whereis(@table) == :undefined do
      :miss
    else
      case :ets.lookup(@table, key) do
        [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
        _ -> :miss
      end
    end
  end

  # A best-effort write: if the owner restarted between the lookup and the insert the
  # table may be momentarily absent, and a caching miss must never fail a search.
  defp store(key, value, expires_at) do
    :ets.insert(@table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
