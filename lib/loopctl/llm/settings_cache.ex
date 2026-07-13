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
  read repopulates read-through. It NEVER serves stale credentials.

  ## Design (mirrors `Loopctl.Knowledge.EmbeddingCircuitBreaker` / `ExportConcurrency`)

  A single GenServer owns a `:public`, `:named_table`, `read_concurrency: true` ETS
  table. Callers read/write it DIRECTLY (`fetch/1`, `put/3`, `invalidate/1`) — the
  GenServer is NEVER on the hot path and can't bottleneck provider throughput. It
  exists ONLY to own the table so it survives the transient request/Task/Oban
  process that populated it. No DB access happens in the GenServer, so there is no
  Ecto Sandbox ownership concern in tests.

  ## Never-stale under the read-through repopulation race (AC-32.3.3)

  Plain cache-aside (invalidate-then-repopulate) has a well-known staleness race:
  a reader can MISS, snapshot the OLD row in its `SELECT`, then a writer commits
  the NEW row and invalidates (a no-op — the entry is already absent), and only
  THEN the slow reader `put`s its now-stale struct — which would persist until the
  next write. That breaks the "NEVER serves stale credentials" invariant right
  after a key rotation (exactly when the entry is empty and an agent is looping).

  We close it with a per-tenant **generation counter** and optimistic version
  checking (the classic check-then-act fix — put the authority in one atomic op).
  Each entry is stamped `{tenant_id, value, generation}` with the generation
  captured BEFORE the DB read (see `Loopctl.Llm.get_settings/1`). `invalidate/1`
  atomically BUMPS the tenant's generation (`:ets.update_counter`). `fetch/1` trusts
  an entry ONLY when its stamp still equals the current generation. Therefore:

    * a reader whose snapshot preceded a committed write captured a generation
      strictly LESS than the post-invalidate one, so its `put` lands with a stale
      stamp and is NEVER trusted — the next read simply reloads (no staleness); and
    * a reader whose capture followed the invalidate necessarily read the committed
      NEW row, so its stamp equals the current generation and its value is fresh.

  No interleaving yields a trusted-but-stale entry, so no fallback TTL is needed:
  `invalidate` (the generation bump), not the wall clock, is the authority. The
  bump is atomic, so the guard needs no serialization through the GenServer — the
  hot read/write paths stay lock-free.

  ## Security (AC-32.3.5)

  The cached struct carries the DECRYPTED plaintext keys in ETS memory only. It is
  NEVER logged, NEVER placed in telemetry tags, and NEVER persisted — a cold start
  or GenServer restart yields an empty table that repopulates read-through. The
  struct's `api_key` / `embedding_api_key` fields are `redact: true`, so an
  accidental `inspect` shows `**redacted**`, but callers must still never log it.

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
  `:miss` when there is no entry OR the entry is STALE (its stamped generation no
  longer matches the tenant's current generation — an `invalidate/1` fired after the
  entry's underlying DB read, so it is rejected rather than served). On a `:miss`
  the caller loads read-through and `put/3`s under a freshly captured generation.
  """
  @spec fetch(Ecto.UUID.t()) :: {:ok, term()} | :miss
  def fetch(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{^tenant_id, value, stamp}] ->
        # Optimistic version check: trust the entry only if no invalidation has
        # bumped the generation since the value's DB read (AC-32.3.3). A mismatch
        # means a concurrent rotation raced this entry's repopulation — treat as a
        # miss so the caller reloads, never serving the stale struct.
        if stamp == current_generation(tenant_id), do: {:ok, value}, else: :miss

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
  BEFORE the value's DB read). Called from the caller process on a read-through
  miss. The entry is only ever SERVED while `read_generation` still matches the
  tenant's current generation, so a repopulation that raced a concurrent
  invalidation is silently ignored on the next `fetch/1`.
  """
  @spec put(Ecto.UUID.t(), term(), non_neg_integer()) :: :ok
  def put(tenant_id, value, read_generation)
      when is_binary(tenant_id) and is_integer(read_generation) do
    :ets.insert(@table, {tenant_id, value, read_generation})
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
  Invalidates the cached entry for `tenant_id`: atomically BUMPS the tenant's
  generation (so any in-flight read-through that captured the prior generation has
  its `put` rejected at `fetch/1`), then deletes the entry so the next read
  repopulates read-through. Called from the settings write path within the same
  call so the next read reflects the change; never serves stale credentials.
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
  Resets (invalidates) a single tenant's cache entry. Preferred over any global
  wipe in async tests: the cache is tenant-scoped, so per-tenant reset never races
  concurrent tests' entries. Alias of `invalidate/1`.
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

    {:ok, %{table: table}}
  end
end
