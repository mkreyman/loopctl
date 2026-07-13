defmodule Loopctl.Auth.ApiKeyCache do
  @moduledoc """
  Stable, supervised OWNER of the ETS table caching resolved API keys by
  `key_hash` for the authentication hot path (US-33.3).

  Every authenticated request funnels through `Loopctl.Auth.verify_api_key/1`,
  which SHA-256-hashes the raw key and looks the hash up in `api_keys` (via the
  BYPASSRLS `AdminRepo`) with `revoked_at`/`expires_at` guards and `preload:
  [:tenant]`. Doing that DB SELECT on EVERY request is the dominant AdminRepo
  cost on the hot path. This cache turns a per-REQUEST SELECT into a per-CHANGE
  one: the resolved `%ApiKey{}` (with its `:tenant` preloaded, carrying
  `custody_halted_at`) is stored in ETS keyed by `key_hash`, and every writer
  that revokes/rotates/mutates a key invalidates the entry so the next request
  re-loads read-through.

  This module removes ONLY the SELECT. The per-request `last_used_at` UPDATE
  (`Loopctl.Auth` `update_last_used/1`) is untouched and still fires on every
  request — US-33.4 owns debouncing that write (AC-33.3.6).

  ## Security — a stale cache must NEVER authenticate a revoked/rotated key

  This is an auth boundary, so correctness of invalidation is a hard release
  gate. Three layers guarantee no revoked/rotated key is ever served stale:

    * **Prompt, in-band invalidation (primary).** EVERY code path that sets
      `api_keys.revoked_at` or mutates a key (single revoke, rotation grace via
      `expires_at`, the dispatch-cascade `update_all` in `Loopctl.Dispatches`
      and `Loopctl.Workers.RevokeExpiredDispatchesWorker`) calls
      `invalidate_cluster/1` for the affected `key_hash` within the same
      operation. A revoked key is rejected on the VERY NEXT request, not after
      the TTL.
    * **Read-time re-enforcement.** On a cache HIT the SQL `revoked_at`/
      `expires_at` guards are no longer applied, so `verify_api_key/1`
      re-enforces them against wall-clock now on the cached struct
      (AC-33.3.5): a cached-but-now-expired key is rejected exactly like an
      uncached one.
    * **Bounded TTL backstop (defense-in-depth).** Each entry carries a short
      wall-bounded TTL (config, default 60s, checked lazily on read + swept
      periodically). Even if some future invalidation path is missed, the stale
      entry self-heals — is re-validated against the DB — within the TTL rather
      than persisting.

  ## No secrets logged (AC-33.3.7)

  The module NEVER logs, `inspect`s, or telemetry-tags a `key_hash` or a raw
  key. A cold start / GenServer restart yields an empty table that repopulates
  read-through — nothing secret is persisted.

  ## Design (mirrors `Loopctl.Llm.SettingsCache`, US-32.3)

  A single GenServer owns a `:public`, `:named_table`, `read_concurrency: true`
  ETS table. Callers read/write it DIRECTLY (`fetch/1`, `put/3`,
  `invalidate/1`) — the GenServer is NEVER on the hot read path and can't
  bottleneck request throughput. It exists to own the table (so it survives the
  transient request/Task/Oban process that populated it), to run the periodic
  TTL sweep, and to bridge cross-node invalidation broadcasts. No DB access
  happens in the GenServer, so there is no Ecto Sandbox ownership concern in
  tests.

  ## Never-stale under the read-through repopulation race

  Plain cache-aside has a well-known staleness race: a reader can MISS, snapshot
  the OLD row in its SELECT, then a writer revokes the key and invalidates (a
  no-op — the entry is already absent), and only THEN the slow reader `put`s its
  now-stale struct, which would persist until the next write. Right after a
  revocation, that would authenticate a revoked key.

  We close it with a per-`key_hash` **generation counter** and optimistic
  version checking. Each entry is stamped `{key_hash, value, generation,
  expires_at}` with the generation captured BEFORE the DB read (see
  `Loopctl.Auth.verify_api_key/1`). `invalidate/1` atomically BUMPS the
  generation (`:ets.update_counter`). `fetch/1` trusts an entry ONLY when its
  stamp still equals the current generation AND it has not passed its TTL. A
  reader whose snapshot preceded a committed revoke captured a strictly LESS
  generation, so its `put` lands with a stale stamp and is never trusted — the
  next read reloads and rejects the revoked key.

  ## Cross-node invalidation

  The table is `:named_table` (node-LOCAL); Erlang clustering does NOT share
  ETS. `invalidate_cluster/1` busts this node synchronously AND broadcasts over
  `Phoenix.PubSub` so peer nodes bust their node-local entries within a message
  hop — a revocation must not authenticate on a peer node either. The `key_hash`
  travels only over internal cluster PubSub (never logged/telemetry-tagged), and
  the hash alone cannot authenticate (the raw-key preimage is required); a
  dropped broadcast is backstopped by the bounded TTL.

  ## Tenant isolation (AC-33.3.5)

  Entries are keyed strictly by `key_hash`, which is globally unique across all
  tenants, so an entry is self-scoped: tenant A's key can never be returned for
  tenant B, and revoking A's key never affects B's cached entry.
  """

  use GenServer

  alias Loopctl.Auth.ApiKey

  @table :loopctl_api_key_cache

  # Cross-node invalidation bridge. Revocation/rotation writers broadcast here so
  # peer nodes bust their node-local ETS promptly (Erlang clustering does not
  # share ETS). The topic carries only a key_hash on an internal cluster channel.
  @pubsub Loopctl.PubSub
  @invalidate_topic "auth:api_key_cache:invalidate"

  # Bounded safety-net TTL (config-driven, default 60s — within the 30-60s range
  # AC-33.3.4 specifies). Even if a future invalidation path is missed or a
  # cross-node broadcast is dropped, a cached entry is evicted after at most this
  # long, on the next `fetch/1` (lazy) or the periodic sweep (active). Prompt
  # invalidation is via the generation bump + PubSub; this is only the backstop.
  @ttl_ms Application.compile_env(:loopctl, [__MODULE__, :ttl_ms], :timer.seconds(60))
  @sweep_interval_ms :timer.seconds(30)

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads the cached `%ApiKey{}` for `key_hash` directly from ETS.

  Returns `{:ok, %ApiKey{}}` (with `:tenant` preloaded) on a fresh cache HIT, or
  `:miss` when there is no entry, the entry is STALE (its stamped generation no
  longer matches — an `invalidate/1` fired after the entry's DB read), OR the
  entry has passed its TTL (the bounded backstop). On a `:miss` the caller loads
  read-through and `put/3`s under a freshly captured generation.

  A cache HIT does NOT re-check `revoked_at`/`expires_at` — the caller
  (`verify_api_key/1`) re-enforces those against wall-clock now (AC-33.3.5).
  """
  @spec fetch(String.t()) :: {:ok, ApiKey.t()} | :miss
  def fetch(key_hash) when is_binary(key_hash) do
    case :ets.lookup(@table, key_hash) do
      [{^key_hash, value, stamp, expires_at}] ->
        if stamp == current_generation(key_hash) and not expired?(expires_at),
          do: {:ok, value},
          else: :miss

      [] ->
        :miss
    end
  rescue
    # The table only vanishes if the owner is (transiently) down mid-restart; a
    # miss makes the caller fall back to the DB read-through — never a crash.
    ArgumentError -> :miss
  end

  @doc """
  Returns the current cache generation for `key_hash` — capture this BEFORE a
  read-through DB load and pass it to `put/3`, so a revoke/rotation that
  invalidates during the load is detected and the repopulation rejected at
  `fetch/1` (never serves a stale/revoked key).
  """
  @spec generation(String.t()) :: non_neg_integer()
  def generation(key_hash) when is_binary(key_hash) do
    current_generation(key_hash)
  rescue
    ArgumentError -> 0
  end

  @doc """
  Stores the resolved `%ApiKey{}` for `key_hash` in ETS, stamped with
  `read_generation` (captured BEFORE the value's DB read) and a wall-bounded
  expiry. Called from the caller process on a read-through miss. The entry is
  only ever SERVED while `read_generation` still matches the current generation
  AND it is within its TTL.
  """
  @spec put(String.t(), ApiKey.t(), non_neg_integer()) :: :ok
  def put(key_hash, %ApiKey{} = value, read_generation)
      when is_binary(key_hash) and is_integer(read_generation) do
    :ets.insert(@table, {key_hash, value, read_generation, now_ms() + @ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Convenience `put` that stamps `value` with the CURRENT generation.

  Prefer `put/3` with a generation captured before the DB read on the
  read-through path — this arity is for direct/manual population where no
  concurrent DB snapshot is in flight (e.g. seeding a known-fresh value in
  tests).
  """
  @spec put(String.t(), ApiKey.t()) :: :ok
  def put(key_hash, %ApiKey{} = value) when is_binary(key_hash) do
    put(key_hash, value, generation(key_hash))
  end

  @doc """
  Invalidates the cached entry for `key_hash` ON THIS NODE: atomically BUMPS the
  generation (so any in-flight read-through that captured the prior generation
  has its `put` rejected at `fetch/1`), then deletes the entry so the next read
  repopulates read-through.

  This is the node-local primitive; key writers use `invalidate_cluster/1` so
  peer nodes bust their node-local entries too.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(key_hash) when is_binary(key_hash) do
    bump_generation(key_hash)
    :ets.delete(@table, key_hash)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidates `key_hash` on THIS node (see `invalidate/1`) AND broadcasts the
  invalidation to peer nodes over `Phoenix.PubSub` so their node-local ETS busts
  promptly — the table is `:named_table` (node-local) and Erlang clustering does
  NOT share ETS.

  EVERY api-key revoke/rotate/mutate writer calls this so a revocation is
  reflected cluster-wide within a PubSub hop, not just on the node that handled
  the write. If the broadcast is dropped (netsplit) the bounded TTL still evicts
  the peer's stale entry.
  """
  @spec invalidate_cluster(String.t()) :: :ok
  def invalidate_cluster(key_hash) when is_binary(key_hash) do
    invalidate(key_hash)
    # Broadcast via the owner so we can exclude THIS node's subscriber from the
    # fan-out (no self-echo). GenServer.cast is safe if the owner is momentarily
    # down mid-restart — the local invalidate already ran.
    GenServer.cast(__MODULE__, {:broadcast_invalidate, key_hash})
    :ok
  end

  @doc """
  Resets (invalidates) a single `key_hash` entry on this node. Alias of
  `invalidate/1`; preferred over any global wipe in async tests since the cache
  is key_hash-scoped and fixtures produce unique hashes.
  """
  @spec reset(String.t()) :: :ok
  def reset(key_hash) when is_binary(key_hash), do: invalidate(key_hash)

  @doc false
  def table_name, do: @table

  @doc false
  def ttl_ms, do: @ttl_ms

  # --- Private ---

  # A key_hash's generation lives under a distinct `{:gen, key_hash}` 2-tuple key
  # that a binary-`key_hash` `fetch/1` lookup can never match, so it never
  # collides with a cached-value entry. Defaults to 0 for a hash never
  # invalidated.
  defp current_generation(key_hash) do
    case :ets.lookup(@table, {:gen, key_hash}) do
      [{{:gen, ^key_hash}, gen}] -> gen
      [] -> 0
    end
  end

  # Atomically increment the generation (creating it at 1 on first bump).
  # `:ets.update_counter/4` is lock-free and serializes concurrent invalidations.
  defp bump_generation(key_hash) do
    :ets.update_counter(@table, {:gen, key_hash}, {2, 1}, {{:gen, key_hash}, 0})
  end

  # Monotonic clock (not affected by wall-clock jumps) for TTL comparisons.
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp expired?(expires_at), do: now_ms() >= expires_at

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    # Create + own the table here (in the GenServer process) so it persists for
    # the node's lifetime. Idempotent if it somehow already exists.
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true
          ])

        existing ->
          existing
      end

    # Subscribe so a PEER node's invalidation broadcast busts THIS node's entry.
    # `Phoenix.PubSub` starts strictly before this owner in the supervision tree.
    Phoenix.PubSub.subscribe(@pubsub, @invalidate_topic)
    schedule_sweep()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:broadcast_invalidate, key_hash}, state) do
    # Fan out to peer nodes, excluding self() (this node's subscriber is the
    # owner itself) so the originating node does not re-process its own
    # invalidation.
    _ =
      Phoenix.PubSub.broadcast_from(@pubsub, self(), @invalidate_topic, {:invalidate, key_hash})

    {:noreply, state}
  end

  @impl true
  def handle_info({:invalidate, key_hash}, state) when is_binary(key_hash) do
    # A peer node revoked/rotated this key; bust our node-local entry.
    invalidate(key_hash)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Actively evict expired entries so cached auth material does not linger past
  # the TTL. Only the 4-tuple value entries carry an expiry; the 2-tuple
  # `{:gen, _}` generation entries never match this head.
  defp sweep_expired do
    now = now_ms()
    match_spec = [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  rescue
    ArgumentError -> 0
  end
end
