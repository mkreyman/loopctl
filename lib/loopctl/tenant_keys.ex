defmodule Loopctl.TenantKeys do
  @moduledoc """
  US-26.0.2 — Reads and caches tenant audit signing private keys.

  Private keys are stored in the Fly.io secret store (via the
  `Loopctl.Secrets` facade). This module caches them in an ETS table
  for 5 minutes to avoid hitting the secret store on every request.

  ## ETS table

  Created at application start (see `Loopctl.Application`). Table name is
  `:tenant_key_cache`. Entries are `{tenant_id, result, expires_at, epoch}` — the
  `{:ok, key}` / `{:error, reason}` returned, failures included on a short TTL.

  ## Cross-node invalidation

  ETS is node-LOCAL — Erlang clustering does not share it — and this app runs
  several Fly machines. `invalidate/1` busts only the node it runs on, so a
  rotation performed on one node left every PEER signing with the SUPERSEDED
  private key until its own entry expired. That is not a stale read: a capability
  signed by a retired key verifies as `:invalid_signature`
  (`Capabilities.signing_keys/2` admits a historical key only for the window it
  was live, and a token minted AFTER the rotation falls outside it), which
  `Progress.record_cap_refusal/4` chains as `capability_forged`, `byzantine: true`
  — a benign rotation manufacturing forgery evidence on every peer. An STH signed
  on a peer diverges the same way.

  So every writer calls `invalidate_cluster/1`, which busts this node AND
  broadcasts over `Phoenix.PubSub`; the supervised owner below subscribes and
  busts its own node on receipt. Only a tenant UUID travels, on an internal
  cluster topic. A dropped broadcast (netsplit) is backstopped twice: by the
  bounded TTL, and by `Capabilities.mint/4`, which checks its own signature
  against the key the tenant ADVERTISES and re-signs once off a busted cache.

  This module mirrors `Loopctl.Auth.ApiKeyCache` / `Loopctl.Llm.SettingsCache`.
  It is a THIN owner: the table is still created by `init_cache/0` at application
  start (tests call it directly), and reads/writes go straight to ETS, so the
  GenServer is never on the hot path.
  """

  use GenServer

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Secrets
  alias Loopctl.Tenants.Tenant

  @cache_table :tenant_key_cache
  @ttl_seconds 300

  @pubsub Loopctl.PubSub
  @invalidate_topic "tenant_keys:invalidate"

  # Failures are cached because the caller that hurts most repeats: `verifier_seed/2` asks on
  # EVERY request-review, so an uncached miss costs an AdminRepo query (a deliberately
  # 3-connection pool) plus a secret-store trip, per call — `:not_found` most of all, since a
  # tenant with no audit key yet answers it for as long as it has none, a PERMANENT storm.
  # The TTL is short so a resolved outage, or a key just written, is not extended into
  # spurious `verifier_needed`; a path that WRITES a key calls `invalidate/1`, not the TTL.
  @negative_ttl_seconds 15

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Ensure the ETS cache table exists. Called from `Application.start/2`.
  """
  @spec init_cache() :: :ok
  def init_cache do
    # Public access: rotation runs in request processes that need to
    # invalidate cache entries. A GenServer wrapper would be cleaner
    # but adds complexity for a cache that only holds ephemeral data.
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Get the ed25519 private key for a tenant. Checks the ETS cache first;
  falls through to the secret store on miss or expiry.

  Returns `{:ok, private_key_bytes}` or `{:error, reason}`.
  """
  @spec get_private_key(Ecto.UUID.t()) :: {:ok, binary()} | {:error, term()}
  def get_private_key(tenant_id) when is_binary(tenant_id) do
    now = System.system_time(:second)
    epoch = epoch(tenant_id)

    case :ets.lookup(@cache_table, tenant_id) do
      [{^tenant_id, result, expires_at, ^epoch}] when expires_at > now -> result
      _ -> fetch_and_cache(tenant_id, now, epoch)
    end
  end

  @doc """
  Invalidate the cached key for a tenant ON THIS NODE (after key rotation or
  provisioning).

  This is the node-local primitive. Writers use `invalidate_cluster/1` so peer
  nodes stop signing with the superseded key too.
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(tenant_id) do
    key = {:epoch, tenant_id}
    :ets.update_counter(@cache_table, key, {2, 1}, {key, 0})
    :ets.delete(@cache_table, tenant_id)
    :ok
  end

  @doc """
  Invalidate `tenant_id` on THIS node (see `invalidate/1`) AND broadcast the
  invalidation to peers, so a rotation takes effect fleet-wide within a message
  hop rather than after each node's own TTL.

  EVERY path that writes a tenant's audit private key must call this: the whole
  point of a rotation is that nothing signs with the old key afterwards, and a
  peer that does produces `capability_forged` / divergent-STH evidence out of a
  routine operation (see the moduledoc).
  """
  @spec invalidate_cluster(Ecto.UUID.t()) :: :ok
  def invalidate_cluster(tenant_id) do
    invalidate(tenant_id)
    # Broadcast through the owner so its own subscription is excluded from the
    # fan-out (no self-echo). A cast is safe if the owner is momentarily down
    # mid-restart — the local invalidation has already run.
    GenServer.cast(__MODULE__, {:broadcast_invalidate, tenant_id})
    :ok
  end

  # Invalidation must cover a fetch already IN FLIGHT: deleting the row is not enough, because
  # a slow fetch that began before a rotation and fails after it lands on the empty table and
  # poisons the freshly rotated key for the negative TTL. An entry carries the epoch it was
  # fetched under and a read takes only its own, so one bump orphans them all.
  defp epoch(tenant_id), do: :ets.lookup_element(@cache_table, {:epoch, tenant_id}, 2, 0)

  defp fetch_and_cache(tenant_id, now, epoch) do
    import Ecto.Query

    case AdminRepo.one(from(t in Tenant, where: t.id == ^tenant_id, select: t.slug)) do
      nil ->
        cache_negative(tenant_id, {:error, :tenant_not_found}, now, epoch)

      slug ->
        secret_name = Secrets.audit_key_secret_name(slug)

        case Secrets.get(secret_name) do
          {:ok, encoded} ->
            # Fly secrets store keys as base64 (set via FlyAdapter.set/2).
            # Decode to raw bytes for :crypto.sign/5.
            key = decode_key(encoded)
            :ets.insert(@cache_table, {tenant_id, {:ok, key}, now + @ttl_seconds, epoch})
            {:ok, key}

          {:error, reason} ->
            Logger.warning(
              "Failed to fetch audit key for tenant #{tenant_id}: #{inspect(reason)}"
            )

            cache_negative(tenant_id, {:error, reason}, now, epoch)
        end
    end
  end

  # A failure must never overwrite a LIVE positive entry — a slow error can land after a
  # concurrent success. `select_replace` tests "non-positive or already expired" and writes in
  # ONE atomic op (lookup-then-insert leaves a window); it matches nothing when the row is
  # absent, so `insert_new` covers that without clobbering a racing writer.
  defp cache_negative(tenant_id, result, now, epoch) do
    entry = {tenant_id, result, now + @negative_ttl_seconds, epoch}
    stale = {:orelse, {:"/=", {:element, 1, :"$1"}, :ok}, {:"=<", :"$2", now}}
    ms = [{{tenant_id, :"$1", :"$2", :_}, [stale], [{:const, entry}]}]

    if :ets.select_replace(@cache_table, ms) == 0, do: :ets.insert_new(@cache_table, entry)

    result
  end

  # Keys may be stored as base64 (FlyAdapter encodes) or raw bytes (test mocks).
  # Try base64 decode first; if it fails, assume raw bytes.
  defp decode_key(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, raw} when byte_size(raw) == 32 -> raw
      _ -> value
    end
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    # Idempotent: the table is normally already created by `init_cache/0` at
    # application start (and by tests directly), so this owner only guarantees it
    # exists before it starts bridging invalidations.
    init_cache()

    # `Phoenix.PubSub` starts strictly before this owner in the supervision tree.
    Phoenix.PubSub.subscribe(@pubsub, @invalidate_topic)

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:broadcast_invalidate, tenant_id}, state) do
    _ =
      Phoenix.PubSub.broadcast_from(@pubsub, self(), @invalidate_topic, {:invalidate, tenant_id})

    {:noreply, state}
  end

  @impl true
  def handle_info({:invalidate, tenant_id}, state) when is_binary(tenant_id) do
    # A peer node rotated (or provisioned) this tenant's audit key; stop serving
    # the superseded one from this node's cache.
    invalidate(tenant_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
