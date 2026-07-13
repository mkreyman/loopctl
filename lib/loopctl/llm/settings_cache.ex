defmodule Loopctl.Llm.SettingsCache do
  @moduledoc """
  Stable, supervised OWNER of the ETS table caching resolved+decrypted per-tenant
  LLM settings (US-32.3).

  Every embedding/completion provider call funnels through `Loopctl.Llm.get_settings/1`,
  which reads the tenant's `tenant_llm_settings` row and Cloak-decrypts the two
  BYO API keys (Anthropic + embedding). Doing that DB read + AES-256-GCM decrypt on
  every provider call is wasteful when the settings change rarely. This cache turns
  a per-CALL DB+decrypt into a per-CHANGE one: the resolved+decrypted
  `TenantLlmSettings` struct is stored in ETS keyed by `tenant_id`, and the sole
  write path (`Loopctl.Llm.upsert_settings/2`) invalidates the entry so the next
  read repopulates read-through.

  ## Staleness bounds — what "fresh" actually guarantees

  The cache is a `:named_table`, so the ETS table is **node-LOCAL**: Erlang
  clustering does NOT share ETS. That shapes the staleness guarantee, which is
  layered (strongest first):

    * **Intra-node, exact:** on the node that processed the write, the entry is
      busted synchronously in the same call, and the generation counter (below)
      closes the read-through repopulation race. That node NEVER serves stale.
    * **Cross-node, prompt:** `invalidate_cluster/1` (called by the write path)
      broadcasts the invalidation over `Phoenix.PubSub` so every OTHER node busts
      its node-local entry within a message hop — not just the node that handled
      the write. In a healthy cluster this makes cross-node staleness effectively
      as short as a PubSub round-trip.
    * **Bounded safety-net:** every entry carries a wall-bounded TTL
      (#{div(:timer.minutes(5), 60_000)} min). Even if a broadcast is DROPPED (netsplit /
      PubSub blip) or a post-commit `invalidate/1` is SKIPPED (a crash in the gap
      between COMMIT and the invalidate call), the stale entry — and the decrypted
      secret it holds — is evicted after at most the TTL, on the next `fetch/1` or
      the periodic sweep. This is the backstop the story's technical note asks for
      ("consider a fallback TTL only if a mutation path could bypass the API" —
      another node's write path, and a crash between commit and invalidate, are
      exactly such bypasses).

  So the invariant is precisely: **no node serves credentials staler than the TTL,
  and the writing node plus every reachable peer are consistent within a PubSub
  hop** — not an unconditional "never stale" across a partitioned cluster.

  ## Design (mirrors `Loopctl.Knowledge.EmbeddingCircuitBreaker` / `ExportConcurrency`)

  A single GenServer owns a `:public`, `:named_table`, `read_concurrency: true` ETS
  table. Callers read/write it DIRECTLY (`fetch/1`, `put/3`, `invalidate/1`) — the
  GenServer is NEVER on the hot read path and can't bottleneck provider throughput.
  It exists to own the table (so it survives the transient request/Task/Oban
  process that populated it), to run the periodic TTL sweep, and to bridge
  cross-node invalidation broadcasts. No DB access happens in the GenServer, so
  there is no Ecto Sandbox ownership concern in tests.

  ## Never-stale under the read-through repopulation race (AC-32.3.3)

  Plain cache-aside (invalidate-then-repopulate) has a well-known staleness race:
  a reader can MISS, snapshot the OLD row in its `SELECT`, then a writer commits
  the NEW row and invalidates (a no-op — the entry is already absent), and only
  THEN the slow reader `put`s its now-stale struct — which would persist until the
  next write. That breaks the intra-node freshness invariant right after a key
  rotation (exactly when the entry is empty and an agent is looping).

  We close it with a per-tenant **generation counter** and optimistic version
  checking (the classic check-then-act fix — put the authority in one atomic op).
  Each entry is stamped `{tenant_id, value, generation, expires_at}` with the
  generation captured BEFORE the DB read (see `Loopctl.Llm.get_settings/1`).
  `invalidate/1` atomically BUMPS the tenant's generation (`:ets.update_counter`).
  `fetch/1` trusts an entry ONLY when its stamp still equals the current generation
  AND it has not passed its TTL. Therefore:

    * a reader whose snapshot preceded a committed write captured a generation
      strictly LESS than the post-invalidate one, so its `put` lands with a stale
      stamp and is NEVER trusted — the next read simply reloads (no staleness); and
    * a reader whose capture followed the invalidate necessarily read the committed
      NEW row, so its stamp equals the current generation and its value is fresh.

  No interleaving yields a trusted-but-stale entry on the writing node:
  `invalidate` (the generation bump), not the wall clock, is the intra-node
  authority. The bump is atomic, so the guard needs no serialization through the
  GenServer — the hot read/write paths stay lock-free. The TTL is orthogonal: it
  caps staleness for the cross-node / crash-window cases the generation counter
  cannot see (those live on a different node's ETS, or never reached `invalidate`).

  ## Security (AC-32.3.5)

  The cached struct carries the DECRYPTED plaintext keys in ETS memory only. Two
  guardrails bound the blast radius of a `:public`, `:named_table` that aggregates
  every tenant's plaintext keys under one well-known name:

    * **Never log / inspect the plaintext downstream.** The struct's `api_key` /
      `embedding_api_key` fields are `redact: true`, so an accidental `inspect`
      shows `**redacted**` — but callers must still never log the resolved value.
      This module itself never logs, inspects, or telemetry-tags the value.
    * **Bounded residency.** The TTL + periodic sweep actively evict entries so a
      decrypted secret does not linger in memory indefinitely after its last use;
      combined with never persisting it (a cold start / GenServer restart yields an
      empty table that repopulates read-through), plaintext exposure in a heap /
      crash dump is time-boxed to at most the TTL.

  ## Tenant isolation (AC-32.3.4)

  Entries are keyed strictly by `tenant_id`, so tenant A's entry can never be
  returned for tenant B, and rotating A's key never affects B's cached entry.

  ## Negative caching

  A tenant with NO settings row (`nil`) is read on every provider call too, so the
  cache stores `nil` as a first-class value (distinct from a cache MISS). Because
  `upsert_settings/2` is the ONLY creation path and it invalidates the entry, a
  cached `nil` is busted the moment a tenant configures a key.
  """

  use GenServer

  @table :loopctl_tenant_llm_settings

  # Cross-node invalidation bridge. The write path broadcasts here so peer nodes
  # bust their node-local ETS promptly (Erlang clustering does not share ETS).
  @pubsub Loopctl.PubSub
  @invalidate_topic "llm:settings_cache:invalidate"

  # Bounded safety-net TTL: even if the cross-node broadcast is dropped (netsplit)
  # or a post-commit `invalidate/1` is skipped (crash between COMMIT and the call),
  # a cached entry — and the decrypted secret it holds — is evicted after at most
  # this long, on the next `fetch/1` (lazy) or the periodic sweep (active). Prompt
  # invalidation is via the generation bump + PubSub; this is only the backstop.
  @ttl_ms :timer.minutes(5)
  @sweep_interval_ms :timer.minutes(1)

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads the cached settings for `tenant_id` directly from ETS.

  Returns `{:ok, value}` on a cache HIT — where `value` is the cached
  `TenantLlmSettings.t()` OR `nil` (negative cache for a tenant with no row) — or
  `:miss` when there is no entry, the entry is STALE (its stamped generation no
  longer matches the tenant's current generation — an `invalidate/1` fired after
  the entry's underlying DB read), OR the entry has passed its TTL (the bounded
  safety-net for a dropped cross-node broadcast / skipped invalidate). On a `:miss`
  the caller loads read-through and `put/3`s under a freshly captured generation.
  """
  @spec fetch(Ecto.UUID.t()) :: {:ok, term()} | :miss
  def fetch(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{^tenant_id, value, stamp, expires_at}] ->
        # Trust the entry only if (a) no invalidation bumped the generation since
        # the value's DB read (AC-32.3.3 intra-node race) AND (b) it has not passed
        # its TTL (cross-node / crash-window backstop). Either failing => miss, so
        # the caller reloads and never serves stale.
        if stamp == current_generation(tenant_id) and not expired?(expires_at),
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
  Returns the tenant's current cache generation — capture this BEFORE a read-through
  DB load and pass it to `put/3`, so a rotation that invalidates during the load is
  detected and the repopulation rejected at `fetch/1` (never serves stale).
  """
  @spec generation(Ecto.UUID.t()) :: non_neg_integer()
  def generation(tenant_id) when is_binary(tenant_id) do
    current_generation(tenant_id)
  rescue
    ArgumentError -> 0
  end

  @doc """
  Stores the resolved settings `value` (a `TenantLlmSettings.t()` or `nil`) for
  `tenant_id` in ETS, stamped with `read_generation` (the generation captured
  BEFORE the value's DB read) and a wall-bounded expiry (#{div(:timer.minutes(5), 60_000)} min).
  Called from the caller process on a read-through miss. The entry is only ever
  SERVED while `read_generation` still matches the tenant's current generation AND
  it is within its TTL, so a repopulation that raced a concurrent invalidation — or
  outlived a dropped cross-node broadcast — is not served on the next `fetch/1`.
  """
  @spec put(Ecto.UUID.t(), term(), non_neg_integer()) :: :ok
  def put(tenant_id, value, read_generation)
      when is_binary(tenant_id) and is_integer(read_generation) do
    :ets.insert(@table, {tenant_id, value, read_generation, now_ms() + @ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Convenience `put` that stamps `value` with the tenant's CURRENT generation.

  Prefer `put/3` with a generation captured before the DB read on the read-through
  path — this arity is for direct/manual population where no concurrent DB snapshot
  is in flight (e.g. seeding a known-fresh value in tests).
  """
  @spec put(Ecto.UUID.t(), term()) :: :ok
  def put(tenant_id, value) when is_binary(tenant_id) do
    put(tenant_id, value, generation(tenant_id))
  end

  @doc """
  Invalidates the cached entry for `tenant_id` ON THIS NODE: atomically BUMPS the
  tenant's generation (so any in-flight read-through that captured the prior
  generation has its `put` rejected at `fetch/1`), then deletes the entry so the
  next read repopulates read-through.

  This is the node-local primitive; the settings write path uses
  `invalidate_cluster/1` so peer nodes bust their node-local entries too.
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(tenant_id) when is_binary(tenant_id) do
    bump_generation(tenant_id)
    :ets.delete(@table, tenant_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidates `tenant_id` on THIS node (see `invalidate/1`) AND broadcasts the
  invalidation to peer nodes over `Phoenix.PubSub` so their node-local ETS busts
  promptly — the ETS table is `:named_table` (node-local), and Erlang clustering
  does NOT share ETS, so a bump on one node is invisible to the others.

  The settings write path (`Loopctl.Llm.upsert_settings/2`) calls this so a key
  rotation is reflected cluster-wide within a PubSub hop, not just on the node that
  handled the write. If the broadcast is dropped (netsplit) the bounded TTL still
  evicts the peer's stale entry — this is prompt-but-not-guaranteed; the TTL is the
  guarantee.
  """
  @spec invalidate_cluster(Ecto.UUID.t()) :: :ok
  def invalidate_cluster(tenant_id) when is_binary(tenant_id) do
    invalidate(tenant_id)
    # Broadcast off the (rare) write path via the owner so we can exclude THIS
    # node's subscriber from the fan-out (no self-echo). GenServer.cast is safe if
    # the owner is momentarily down mid-restart — the local invalidate already ran.
    GenServer.cast(__MODULE__, {:broadcast_invalidate, tenant_id})
    :ok
  end

  @doc """
  Resets (invalidates) a single tenant's cache entry on this node. Preferred over
  any global wipe in async tests: the cache is tenant-scoped, so per-tenant reset
  never races concurrent tests' entries. Alias of `invalidate/1`.
  """
  @spec reset(Ecto.UUID.t()) :: :ok
  def reset(tenant_id) when is_binary(tenant_id), do: invalidate(tenant_id)

  @doc false
  def table_name, do: @table

  # --- Private ---

  # A tenant's generation lives under a distinct `{:gen, tenant_id}` key — a 2-tuple
  # key that a binary-`tenant_id` `fetch/1` lookup can never match, so it never
  # collides with a cached-settings entry. Defaults to 0 for a tenant that has never
  # been invalidated.
  defp current_generation(tenant_id) do
    case :ets.lookup(@table, {:gen, tenant_id}) do
      [{{:gen, ^tenant_id}, gen}] -> gen
      [] -> 0
    end
  end

  # Atomically increment the tenant's generation (creating it at 1 on first bump).
  # `:ets.update_counter/4` is lock-free and serializes concurrent invalidations, so
  # the generation is a monotonic authority no reader can observe half-applied.
  defp bump_generation(tenant_id) do
    :ets.update_counter(@table, {:gen, tenant_id}, {2, 1}, {{:gen, tenant_id}, 0})
  end

  # Monotonic clock (not affected by wall-clock jumps) for TTL comparisons. Stored
  # per-entry as `now_ms() + @ttl_ms`; compared against `now_ms()` at read/sweep.
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp expired?(expires_at), do: now_ms() >= expires_at

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    # Create + own the table here (in the GenServer process) so it persists for the
    # node's lifetime. Idempotent if it somehow already exists (mirrors
    # ExportConcurrency's whereis guard).
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
    # `Phoenix.PubSub` starts strictly before this owner in the supervision tree
    # (and stays up across our restarts), so the subscribe is safe to do inline.
    Phoenix.PubSub.subscribe(@pubsub, @invalidate_topic)
    schedule_sweep()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:broadcast_invalidate, tenant_id}, state) do
    # Fan out to peer nodes, excluding self() (this node's subscriber is the owner
    # itself) so the originating node does not re-process its own invalidation.
    _ =
      Phoenix.PubSub.broadcast_from(@pubsub, self(), @invalidate_topic, {:invalidate, tenant_id})

    {:noreply, state}
  end

  @impl true
  def handle_info({:invalidate, tenant_id}, state) when is_binary(tenant_id) do
    # A peer node rotated this tenant's settings; bust our node-local entry.
    invalidate(tenant_id)
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

  # Actively evict expired entries so decrypted secrets do not linger past the TTL
  # even for tenants that are never read again (bounded residency, AC-32.3.5). Only
  # the 4-tuple value entries carry an expiry; the 2-tuple `{:gen, _}` generation
  # entries never match this head, so the monotonic authority is preserved.
  defp sweep_expired do
    now = now_ms()
    match_spec = [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  rescue
    ArgumentError -> 0
  end
end
