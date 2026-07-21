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

  ## Invalidation beats a concurrent refresh: the GENERATION counter

  A refresh pass works from a SNAPSHOT and then blocks on DNS (up to ~6s). Without
  a version check, an `invalidate_tenant/1` landing inside that window is silently
  UNDONE when the pass re-puts the snapshot — a revoked declaration, or a
  `local_only: false` marking read moments before an ENABLE, would come back with a
  brand-new TTL. The same hole exists on the marking read-through path
  (read DB → enable commits → invalidate → put the stale value).

  So every tenant carries a monotonic GENERATION (`generation/1`), bumped by
  `invalidate_local/1` BEFORE the rows are deleted. A writer captures the
  generation BEFORE its slow work (DB read / DNS) and passes it to `put/5`; a put
  whose captured generation is stale is DROPPED. `Loopctl.Egress.Policy` also
  re-reads the marking once when it loses that race, so an ENABLE can never be
  masked for the remainder of the TTL.

  ## Entries EXPIRE and idle entries are evicted

  A pass first sweeps every entry past its hard `expires_at`, then refreshes only
  entries actually USED since the previous pass (`fetch/3` flags them). An entry
  nothing looks up any more is therefore never re-resolved: it simply ages out and
  is swept, instead of costing two DNS lookups per cycle for the life of the node.
  `put/5` also refuses to grow the table past `@max_entries`.

  ## The periodic pass runs OFF the owner process

  `handle_info(:tick, _)` dispatches the pass to a monitored child process. The
  owner is also the PubSub invalidation subscriber and the broadcast relay, so a
  pass running IN it would queue this node's outgoing invalidation broadcast — and
  a peer's incoming one — behind N x up-to-6s of DNS, which is exactly the
  "peers bust within a hop" promise above. At most one pass runs at a time.

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
  @gen_table :loopctl_egress_pin_generations
  @pubsub Loopctl.PubSub
  @invalidate_topic "egress:pin_cache:invalidate"

  # Hard ceiling on resident entries. The pin table is keyed by
  # `(tenant_id, scope_key, host)` and hosts can come from tenant-supplied ingest
  # URLs, so an unbounded table is a memory amplifier. Past the cap NEW keys are
  # not admitted (existing ones still refresh) until the sweep frees room.
  @max_entries 50_000

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
          used: boolean(),
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
          used: boolean(),
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

  @doc """
  Reads the cached entry, or `:miss` when absent or past its hard TTL.

  A hit FLAGS the entry as used (once per refresh cycle — the flag is only written
  when it is currently `false`), which is what makes the refresher re-resolve the
  live working set instead of every host ever classified.
  """
  @spec fetch(Ecto.UUID.t(), String.t(), key_host()) :: {:ok, cached()} | :miss
  def fetch(tenant_id, scope_key, host) do
    key = {tenant_id, scope_key, host}

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        if now_ms() >= entry.expires_at do
          :miss
        else
          {:ok, mark_used(key, entry)}
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp mark_used(_key, %{used: true} = entry), do: entry

  defp mark_used(key, entry) do
    used = Map.put(entry, :used, true)
    :ets.insert(@table, {key, used})
    used
  rescue
    ArgumentError -> entry
  end

  @doc """
  Stores a freshly classified entry with a jittered pre-expiry refresh point.

  `opts[:generation]` is the tenant generation the CALLER captured BEFORE its slow
  work (a DB marking read, a DNS resolution). When it no longer matches, an
  `invalidate_tenant/1` landed in that window and the write is DROPPED — the built
  entry is still returned to the caller, it is simply not cached. Without this a
  revocation or an ENABLE is silently resurrected for a full TTL.
  """
  @spec put(Ecto.UUID.t(), String.t(), key_host(), map(), keyword()) :: cached()
  def put(tenant_id, scope_key, host, attrs, opts \\ []) do
    now = now_ms()

    entry =
      attrs
      |> Map.merge(%{
        tenant_id: tenant_id,
        scope_key: scope_key,
        host: host,
        state: :fresh,
        pin_stale: Map.get(attrs, :pin_stale, false),
        used: Map.get(attrs, :used, false),
        # An explicit `:refresh_at` / `:expires_at` in `attrs` WINS, so a caller
        # (and the deterministic refresher test) can steer the schedule; the
        # refresher itself DROPS both keys before re-putting, so a revalidated
        # entry always gets a fresh jittered point and can never loop.
        refresh_at: Map.get(attrs, :refresh_at) || now + jittered_refresh_ms(),
        expires_at: Map.get(attrs, :expires_at) || now + @ttl_ms
      })

    key = {tenant_id, scope_key, host}

    if admit?(key, Keyword.get(opts, :generation), tenant_id) do
      :ets.insert(@table, {key, entry})
    end

    entry
  rescue
    ArgumentError -> Map.merge(attrs, %{state: :fresh, pin_stale: false, used: false})
  end

  # A write is admitted when (a) the caller's captured generation is still current
  # and (b) it does not grow the table past the hard cap.
  defp admit?(key, generation, tenant_id) do
    cond do
      stale_generation?(tenant_id, generation) -> false
      :ets.member(@table, key) -> true
      :ets.info(@table, :size) < @max_entries -> true
      true -> log_capacity_drop(key)
    end
  end

  defp log_capacity_drop(key) do
    Logger.warning(
      "Loopctl.Egress.PinCache: at capacity (#{@max_entries} entries); not admitting " <>
        "#{inspect(elem(key, 2))} — it will be re-classified on demand"
    )

    false
  end

  @doc """
  The tenant's monotonic invalidation generation.

  Capture it BEFORE any slow work whose result you intend to cache, then hand it
  to `put/5`. Returns `0` when the counter table is unavailable (owner restarting),
  which degrades to the pre-generation behaviour rather than refusing to cache.
  """
  @spec generation(Ecto.UUID.t()) :: non_neg_integer()
  def generation(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@gen_table, tenant_id) do
      [{^tenant_id, generation}] -> generation
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "True when `generation` was superseded by an invalidation (`nil` never is)."
  @spec stale_generation?(Ecto.UUID.t(), non_neg_integer() | nil) :: boolean()
  def stale_generation?(_tenant_id, nil), do: false

  def stale_generation?(tenant_id, generation) when is_integer(generation) do
    generation(tenant_id) != generation
  end

  defp bump_generation(tenant_id) do
    _ = :ets.update_counter(@gen_table, tenant_id, {2, 1}, {tenant_id, 0})
    :ok
  rescue
    ArgumentError -> :ok
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

  @doc """
  Drops every entry for a tenant on THIS node only (peer-broadcast handler / tests).

  The generation is bumped BEFORE the delete, so a writer that captured the old
  generation and inserts after the delete is rejected by `put/5` instead of
  resurrecting the invalidated state for a full TTL.
  """
  @spec invalidate_local(Ecto.UUID.t()) :: :ok
  def invalidate_local(tenant_id) when is_binary(tenant_id) do
    bump_generation(tenant_id)
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

  Pass a `tenant_id` in a TEST: the table is globally named and nothing clears it
  between `async: true` tests, so an unscoped pass revalidates a NEIGHBOUR's
  entries through the CALLING process's Mox DNS stub — a differing address set
  flips that neighbour's entry to `pin_stale`. Scoping mirrors why
  `Loopctl.Egress.BlockedBuffer.flush_tenant/1` exists.
  """
  @spec refresh_now(Ecto.UUID.t() | :all) :: non_neg_integer()
  def refresh_now(tenant_id \\ :all), do: refresh_due(tenant_id)

  @doc false
  def table_name, do: @table

  # --- Server ---

  @impl true
  def init(_opts) do
    table = ensure_table(@table, read_concurrency: true)
    _gens = ensure_table(@gen_table, write_concurrency: true)

    # Subscribe so a PEER node's invalidation broadcast busts THIS node's entries.
    # `Phoenix.PubSub` starts strictly before this owner in the supervision tree.
    Phoenix.PubSub.subscribe(@pubsub, @invalidate_topic)
    schedule_tick()
    {:ok, %{table: table, refresh_ref: nil}}
  end

  defp ensure_table(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:set, :public, :named_table] ++ opts)
      existing -> existing
    end
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
    schedule_tick()
    {:noreply, start_refresh(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh_ref: ref} = state) do
    {:noreply, %{state | refresh_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The pass runs in a MONITORED CHILD, never in this process: the owner is also
  # the PubSub invalidation subscriber and the outgoing-broadcast relay, and a pass
  # can block on N x up-to-6s of DNS. Running it here would queue a revocation
  # behind the whole pass on this node AND delay applying a peer's. At most one
  # pass at a time — a still-running pass simply skips this tick.
  defp start_refresh(%{refresh_ref: nil} = state) do
    {_pid, ref} = spawn_monitor(fn -> refresh_due(:all) end)
    %{state | refresh_ref: ref}
  end

  defp start_refresh(state) do
    Logger.debug("Loopctl.Egress.PinCache: previous refresh pass still running; skipping tick")
    state
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # One pass: SWEEP expired entries, then re-resolve every entry that is past its
  # (jittered) refresh point AND was actually used since the previous pass, BEFORE
  # its hard expiry. A refresh that finds a different address set marks the entry
  # `pin_stale` instead of silently adopting the new address.
  #
  # Refreshing only USED entries is what stops the table from becoming a permanent
  # DNS load generator: an entry nothing looks up any more is never re-resolved, so
  # its `expires_at` stands and the next sweep deletes it.
  defp refresh_due(tenant_filter) do
    now = now_ms()
    entries = Enum.filter(all(), &tenant_match?(&1, tenant_filter))

    {expired, live} = Enum.split_with(entries, &(now >= &1.expires_at))
    Enum.each(expired, &delete(&1.tenant_id, &1.scope_key, &1.host))

    {used, _idle} = Enum.split_with(live, &Map.get(&1, :used, false))

    # Clear the usage flag for the next cycle. Idle entries are deliberately left
    # untouched: they age out and the next sweep evicts them.
    Enum.each(used, &clear_used/1)

    # `is_binary(host)` skips the marking entries the policy caches under an atom
    # key in the same table — they carry no pin to revalidate.
    #
    # `:denylisted` entries are skipped too: a private-range host can NEVER
    # revalidate (`Policy.reresolve/1` returns `{:error, :blocked_ip}`), so
    # refreshing one would only flip it to `pin_stale` — masking a permanent
    # refusal behind a transient, un-actionable "re-pin it" and silently stopping
    # the AC-41.4.6 blocked telemetry/audit trail for a still-blocked tenant.
    used
    |> Enum.filter(&refreshable?(&1, now))
    |> Enum.map(&revalidate/1)
    |> Enum.count()
  end

  defp tenant_match?(_entry, :all), do: true
  defp tenant_match?(entry, tenant_id), do: entry.tenant_id == tenant_id

  defp clear_used(entry) do
    key = {entry.tenant_id, entry.scope_key, entry.host}

    case :ets.lookup(@table, key) do
      [{^key, current}] -> :ets.insert(@table, {key, Map.put(current, :used, false)})
      [] -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp refreshable?(entry, now) do
    is_binary(entry.host) and now >= entry.refresh_at and not entry.pin_stale and
      Map.get(entry, :base_verdict) != :denylisted
  end

  defp revalidate(entry) do
    # Capture the tenant generation BEFORE the (blocking, up-to-6s) DNS work: an
    # `invalidate_tenant/1` landing inside that window must WIN, or the re-put
    # below would resurrect the pre-invalidation entry with a brand-new TTL.
    generation = generation(entry.tenant_id)
    mark_revalidating(entry, generation)
    # Drop the schedule so the re-put gets a FRESH jittered refresh point and a
    # fresh hard expiry — otherwise a due entry would stay permanently due.
    base = Map.drop(entry, [:refresh_at, :expires_at])

    case Policy.reresolve(entry) do
      {:ok, ips} when ips == entry.ips ->
        reput(entry, Map.put(base, :ips, ips), generation)

      {:ok, ips} ->
        Logger.info(
          "Loopctl.Egress.PinCache: pinned address set changed for host=#{entry.host}; " <>
            "marking pin_stale (re-pin required)"
        )

        reput(entry, Map.merge(base, %{ips: ips, pin_stale: true}), generation)

      {:error, reason} ->
        Logger.warning(
          "Loopctl.Egress.PinCache: revalidation failed for host=#{entry.host} " <>
            "(#{inspect(reason)}); marking pin_stale"
        )

        reput(entry, Map.put(base, :pin_stale, true), generation)
    end
  end

  defp reput(entry, attrs, generation) do
    put(entry.tenant_id, entry.scope_key, entry.host, attrs, generation: generation)
  end

  defp mark_revalidating(entry, generation) do
    key = {entry.tenant_id, entry.scope_key, entry.host}

    # Same generation guard: the snapshot this pass works from may already have
    # been invalidated, and an unconditional insert would resurrect it.
    if not stale_generation?(entry.tenant_id, generation) and :ets.member(@table, key) do
      :ets.insert(@table, {key, Map.put(entry, :state, :revalidating)})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp jittered_refresh_ms do
    factor = @refresh_floor + :rand.uniform() * @refresh_jitter
    trunc(@ttl_ms * factor)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
