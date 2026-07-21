defmodule Loopctl.Egress.PinCache do
  @moduledoc """
  Stable, supervised OWNER of the ETS table holding resolved + classified egress
  pins (US-41.4, AC-41.4.12).

  ## Why a supervised owner and not a bare TTL

  The hot-path requirement is ONE cheap classification per provider call with no
  network or DB round-trip. A naive `resolve-on-expiry` TTL makes expiry a
  SCHEDULED FLEET-WIDE OUTAGE: every `local_only` tenant hard-refuses at the same
  instant, and a privacy control whose steady state is an outage gets disabled in
  production — which is how the guarantee actually dies. So a named GenServer in
  the application supervision tree re-resolves and re-pins BEFORE expiry, with
  jitter, and entries expose a distinct `:revalidating` state.

  ## Cache key is `(tenant_id, scope_key, host)` — never host alone

  Locality depends on the TENANT's declared list, so a host-keyed cache would let
  tenant A's declaration make a host read as local for tenant B. The scope
  component is `Loopctl.Egress.Scope.key/1`.

  ## Only purpose-INDEPENDENT facts are cached

  An entry stores `base_verdict` (`:network_local | :denylisted | :public`), the
  resolved `ips`, `from_allowlist`, and the host's DECLARED `purposes`. The final
  verdict is derived per read by `Loopctl.Egress.Policy.resolve_verdict/2`.
  Caching a purpose-derived verdict would let the first purpose to touch a host
  fix its verdict for the whole TTL (AC-41.4.5 constraint 2).

  ## Invalidation is explicit, immediate AND CLUSTER-WIDE

  `invalidate_tenant/1` is called on ANY mutation of the tenant's declared
  endpoints, its scope markings, or its endpoint settings — a revoked declaration
  must not keep working for the remainder of the TTL.

  The table is `:named_table`, i.e. node-LOCAL, and Erlang clustering does not
  share ETS — loopctl clusters (DNSCluster is wired in the supervision tree). A
  node-local-only invalidation would therefore leave PEER nodes honouring a
  revoked declaration, and — because the scope's `local_only` MARKING is cached
  here too — would leave a peer answering `local_only: false` for up to the full
  TTL after an ENABLE: a privacy control with a ten-minute activation hole, while
  the posture report attests the tightened posture. So `invalidate_tenant/1` also
  broadcasts over `Phoenix.PubSub` (mirroring `Loopctl.Llm.SettingsCache` and
  `Loopctl.Auth.ApiKeyCache`): peers bust within a hop, and the bounded TTL is
  only the netsplit backstop.

  ## `:pin_stale` is distinct from `:egress_blocked`

  The target deployments (a home Ollama box, a tailscale funnel, a DHCP VPS)
  change IP routinely. When a refresh finds the host now resolves to a DIFFERENT
  address set, the entry is marked `pin_stale` rather than silently adopting the
  new address — the caller gets `{:error, :pin_stale}`, never `:egress_blocked`,
  and recovery is `Loopctl.Egress.Policy.repin/3`, which requires NO role `:user`
  write. Conflating the two would tell an agent "your privacy config is wrong"
  when the truth is "your box got a new lease".
  """

  use GenServer

  require Logger

  # Runtime-only mutual reference: the policy classifies, this owner revalidates.
  alias Loopctl.Egress.Policy

  @table :loopctl_egress_pins
  @pubsub Loopctl.PubSub
  @invalidate_topic "egress:pin_cache:invalidate"

  # Hard expiry. An entry past this is discarded and re-classified lazily.
  @ttl_ms :timer.minutes(10)
  # Re-resolve at ~60-80% of the TTL (jittered per entry) so expiry is never a
  # synchronised cliff.
  @refresh_floor 0.60
  @refresh_jitter 0.20
  @tick_ms :timer.seconds(30)

  @typedoc """
  The third cache-key component. Normally the endpoint HOST; the policy also
  caches a scope's resolved `local_only` marking in this same table under the
  reserved ATOM key `:__marking__`, so the hot path takes one ETS read for the
  marking too (no DB round-trip) and `invalidate_tenant/1` drops both in one
  `match_delete`. The refresher skips non-binary hosts — a marking has no pin.
  """
  @type key_host :: String.t() | atom()

  @type entry :: %{
          tenant_id: Ecto.UUID.t(),
          scope_key: String.t(),
          host: key_host(),
          base_verdict: :network_local | :denylisted | :public,
          from_allowlist: boolean(),
          ips: [:inet.ip_address()],
          purposes: [String.t()],
          state: :fresh | :revalidating,
          pin_stale: boolean(),
          refresh_at: integer(),
          expires_at: integer()
        }

  @typedoc """
  The OTHER shape stored in this table: a scope's resolved `local_only` marking,
  cached under the reserved `:__marking__` key so the hot path reads it from ETS
  instead of the database. It carries no pin, and the refresher skips it.
  """
  @type marking_entry :: %{
          tenant_id: Ecto.UUID.t(),
          scope_key: String.t(),
          host: key_host(),
          local_only: boolean(),
          state: :fresh | :revalidating,
          pin_stale: boolean(),
          refresh_at: integer(),
          expires_at: integer()
        }

  @typedoc "Anything this cache can hold."
  @type cached :: entry() | marking_entry()

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reads the cached entry, or `:miss` when absent or past its hard TTL."
  @spec fetch(Ecto.UUID.t(), String.t(), key_host()) :: {:ok, cached()} | :miss
  def fetch(tenant_id, scope_key, host) do
    key = {tenant_id, scope_key, host}

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        if now_ms() >= entry.expires_at, do: :miss, else: {:ok, entry}

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Stores a freshly classified entry with a jittered pre-expiry refresh point."
  @spec put(Ecto.UUID.t(), String.t(), key_host(), map()) :: cached()
  def put(tenant_id, scope_key, host, attrs) do
    now = now_ms()

    entry =
      attrs
      |> Map.merge(%{
        tenant_id: tenant_id,
        scope_key: scope_key,
        host: host,
        state: :fresh,
        pin_stale: Map.get(attrs, :pin_stale, false),
        # An explicit `:refresh_at` / `:expires_at` in `attrs` WINS, so a caller
        # (and the deterministic refresher test) can steer the schedule; the
        # refresher itself DROPS both keys before re-putting, so a revalidated
        # entry always gets a fresh jittered point and can never loop.
        refresh_at: Map.get(attrs, :refresh_at) || now + jittered_refresh_ms(),
        expires_at: Map.get(attrs, :expires_at) || now + @ttl_ms
      })

    :ets.insert(@table, {{tenant_id, scope_key, host}, entry})
    entry
  rescue
    ArgumentError -> Map.merge(attrs, %{state: :fresh, pin_stale: false})
  end

  @doc "Drops one entry (the re-pin primitive — no role `:user` write required)."
  @spec delete(Ecto.UUID.t(), String.t(), key_host()) :: :ok
  def delete(tenant_id, scope_key, host) do
    :ets.delete(@table, {tenant_id, scope_key, host})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drops EVERY entry for a tenant on THIS node AND on every peer node.

  Called immediately on any mutation of the tenant's declarations, markings or
  endpoint settings (AC-41.4.12). The PubSub fan-out is what makes an ENABLE take
  effect cluster-wide within a hop instead of within the TTL — see the moduledoc.
  """
  @spec invalidate_tenant(Ecto.UUID.t()) :: :ok
  def invalidate_tenant(tenant_id) when is_binary(tenant_id) do
    invalidate_local(tenant_id)
    # Broadcast off the (rare) mutation path via the owner so THIS node's
    # subscriber is excluded from the fan-out (no self-echo). `GenServer.cast` is
    # safe if the owner is momentarily down mid-restart — the local drop already ran.
    _ = safe_cast({:broadcast_invalidate, tenant_id})
    :ok
  end

  @doc "Drops every entry for a tenant on THIS node only (peer-broadcast handler / tests)."
  @spec invalidate_local(Ecto.UUID.t()) :: :ok
  def invalidate_local(tenant_id) when is_binary(tenant_id) do
    :ets.match_delete(@table, {{tenant_id, :_, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_cast(message) do
    GenServer.cast(__MODULE__, message)
  catch
    :exit, _reason -> :ok
  end

  @doc "All cached entries (diagnostics / the refresher / posture)."
  @spec all() :: [cached()]
  def all do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  @doc """
  Marks an entry as DUE for the next refresh pass (sets its refresh point to now).

  A deterministic test seam: `refresh_at` is a MONOTONIC millisecond stamp, which
  is typically negative on Linux, so a test cannot simply write `0` to force a
  refresh. Pair it with `refresh_now/0`.
  """
  @spec mark_due(Ecto.UUID.t(), String.t(), key_host()) :: :ok
  def mark_due(tenant_id, scope_key, host) do
    case fetch(tenant_id, scope_key, host) do
      {:ok, entry} ->
        put(tenant_id, scope_key, host, %{
          entry
          | refresh_at: now_ms(),
            expires_at: entry.expires_at
        })

        :ok

      :miss ->
        :ok
    end
  end

  @doc """
  Runs one refresh pass SYNCHRONOUSLY, in the CALLING process, and returns the
  number of entries revalidated.

  The pass is pure ETS + DNS resolution — the GenServer exists to OWN the table
  and to drive the periodic tick, not to serialize the work — so running it
  in-caller keeps it off a single-mailbox bottleneck AND lets an `async: true`
  test drive the identical code path `handle_info(:tick, _)` runs, without a
  cross-process Mox allowance against a shared, globally named server.
  """
  @spec refresh_now() :: non_neg_integer()
  def refresh_now, do: refresh_due()

  @doc false
  def table_name, do: @table

  # --- Server ---

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        existing ->
          existing
      end

    # Subscribe so a PEER node's invalidation broadcast busts THIS node's entries.
    # `Phoenix.PubSub` starts strictly before this owner in the supervision tree.
    Phoenix.PubSub.subscribe(@pubsub, @invalidate_topic)
    schedule_tick()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:broadcast_invalidate, tenant_id}, state) do
    _ =
      Phoenix.PubSub.broadcast_from(@pubsub, self(), @invalidate_topic, {:invalidate, tenant_id})

    {:noreply, state}
  end

  @impl true
  def handle_info({:invalidate, tenant_id}, state) when is_binary(tenant_id) do
    # A peer node changed this tenant's markings/declarations; bust our entries.
    invalidate_local(tenant_id)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    refresh_due()
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # Re-resolve every entry past its (jittered) refresh point, BEFORE its hard
  # expiry. A refresh that finds a different address set marks the entry
  # `pin_stale` instead of silently adopting the new address.
  defp refresh_due do
    now = now_ms()

    all()
    # `is_binary(host)` skips the marking entries the policy caches under an atom
    # key in the same table — they carry no pin to revalidate.
    #
    # `:denylisted` entries are skipped too: a private-range host can NEVER
    # revalidate (`Policy.reresolve/1` returns `{:error, :blocked_ip}`), so
    # refreshing one would only flip it to `pin_stale` — masking a permanent
    # refusal behind a transient, un-actionable "re-pin it" and silently stopping
    # the AC-41.4.6 blocked telemetry/audit trail for a still-blocked tenant.
    |> Enum.filter(&refreshable?(&1, now))
    |> Enum.map(&revalidate/1)
    |> Enum.count()
  end

  defp refreshable?(entry, now) do
    is_binary(entry.host) and now >= entry.refresh_at and not entry.pin_stale and
      Map.get(entry, :base_verdict) != :denylisted
  end

  defp revalidate(entry) do
    mark_revalidating(entry)
    # Drop the schedule so the re-put gets a FRESH jittered refresh point and a
    # fresh hard expiry — otherwise a due entry would stay permanently due.
    base = Map.drop(entry, [:refresh_at, :expires_at])

    case Policy.reresolve(entry) do
      {:ok, ips} when ips == entry.ips ->
        put(entry.tenant_id, entry.scope_key, entry.host, Map.put(base, :ips, ips))

      {:ok, ips} ->
        Logger.info(
          "Loopctl.Egress.PinCache: pinned address set changed for host=#{entry.host}; " <>
            "marking pin_stale (re-pin required)"
        )

        base
        |> Map.merge(%{ips: ips, pin_stale: true})
        |> then(&put(entry.tenant_id, entry.scope_key, entry.host, &1))

      {:error, reason} ->
        Logger.warning(
          "Loopctl.Egress.PinCache: revalidation failed for host=#{entry.host} " <>
            "(#{inspect(reason)}); marking pin_stale"
        )

        base
        |> Map.put(:pin_stale, true)
        |> then(&put(entry.tenant_id, entry.scope_key, entry.host, &1))
    end
  end

  defp mark_revalidating(entry) do
    :ets.insert(
      @table,
      {{entry.tenant_id, entry.scope_key, entry.host}, Map.put(entry, :state, :revalidating)}
    )
  rescue
    ArgumentError -> :ok
  end

  defp jittered_refresh_ms do
    factor = @refresh_floor + :rand.uniform() * @refresh_jitter
    trunc(@ttl_ms * factor)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
