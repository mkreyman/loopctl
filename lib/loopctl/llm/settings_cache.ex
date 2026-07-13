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
  table. Callers read/write it DIRECTLY (`fetch/1`, `put/2`, `invalidate/1`) — the
  GenServer is NEVER on the hot path and can't bottleneck provider throughput. It
  exists ONLY to own the table so it survives the transient request/Task/Oban
  process that populated it. No DB access happens in the GenServer, so there is no
  Ecto Sandbox ownership concern in tests.

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
  `:miss` when there is no entry (caller should load read-through and `put/2`).
  """
  @spec fetch(Ecto.UUID.t()) :: {:ok, term()} | :miss
  def fetch(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{^tenant_id, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    # The table only vanishes if the owner is (transiently) down mid-restart; a
    # miss makes the caller fall back to the DB read-through — never a crash.
    ArgumentError -> :miss
  end

  @doc """
  Stores the resolved settings `value` (a `TenantLlmSettings.t()` or `nil`) for
  `tenant_id` in ETS. Called from the caller process on a read-through miss.
  """
  @spec put(Ecto.UUID.t(), term()) :: :ok
  def put(tenant_id, value) when is_binary(tenant_id) do
    :ets.insert(@table, {tenant_id, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidates the cached entry for `tenant_id` (delete → next read repopulates
  read-through). Called from the settings write path within the same call so the
  next read reflects the change; never serves stale credentials.
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(tenant_id) when is_binary(tenant_id) do
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
