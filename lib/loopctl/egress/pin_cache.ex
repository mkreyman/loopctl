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
  `put/5` also refuses to grow the table past `@max_entries` — and past a
  per-tenant share of it. Both bounds matter and they bound different things: the
  global one bounds MEMORY, the per-tenant one bounds BLAST RADIUS. Every host in
  this table arrives from tenant-writable input, so without the per-tenant share a
  single tenant PATCHing fresh webhook hostnames in a loop fills the global cap and
  every other tenant's next classification is refused admission — a shared cache
  turned into a cross-tenant denial. The share is PER SHAPE, because the shapes
  grow for different reasons: PINS and NEGATIVE (`:unresolvable`) entries each get
  their own per-tenant budget, and a scope's `:__marking__` is bounded by the
  tenant's `:user`-gated SCOPE count rather than by request volume. Admission is
  gated on `{kind, tenant_id}` COUNTERS (`resident/1`), not on a scan of the pin
  table: `admit?/3` is on the classification hot path.

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

  # The SAME scheme, applied PER TENANT. The global cap alone bounds memory but
  # not BLAST RADIUS: every host in this table arrives from tenant-writable input
  # (a webhook destination, an ingest URL, a chat base url), so one tenant
  # PATCHing fresh hostnames in a loop could hold 50k entries and every OTHER
  # tenant's next classification would be refused admission — a shared cache
  # turned into a cross-tenant denial. The per-tenant share is what keeps the
  # global cap out of reach of any single tenant's REQUEST VOLUME. Mirrors
  # `Loopctl.Egress.BlockedBuffer`'s `@max_hosts_per_window`, the sibling bound on
  # the same tenant-supplied-host cardinality problem.
  @max_entries_per_tenant 1_000

  # The SAME bound for NEGATIVE (`:unresolvable`) entries, counted in their OWN
  # budget. They must not spend the pin budget — a run of DNS misses would starve
  # a tenant's real pins — but they must not be UNBOUNDED either: an unresolvable
  # host is the cheapest row a tenant can produce (no working host required), so
  # leaving the shape uncapped puts the shared global cap back within one tenant's
  # reach, which is the cross-tenant denial the per-tenant share exists to prevent.
  @max_negative_entries_per_tenant 1_000

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

  @typedoc """
  The THIRD shape: a NEGATIVE entry recording that a host failed to classify
  (`Loopctl.Egress.Policy.cache_unresolvable/5`). It exists so an unresolvable
  tenant-supplied host does not repay a multi-second DNS resolve on every
  `Loopctl.Egress.posture/2` call, and it carries a much shorter TTL than a
  success (`Policy.negative_ttl_ms/0`).

  It is a REFUSAL, never a permit: `Policy` short-circuits it back to
  `{:error, reason}` BEFORE `resolve_verdict/2`, whose catch-all would otherwise
  invent a `:non_local` verdict for an entry that has none. It has no pin, so the
  refresher skips it.
  """
  @type unresolvable_entry :: %{
          tenant_id: Ecto.UUID.t(),
          scope_key: String.t(),
          host: key_host(),
          base_verdict: :unresolvable,
          resolve_error: term(),
          ips: [],
          purposes: [],
          state: :fresh | :revalidating,
          pin_stale: boolean(),
          used: boolean(),
          refresh_at: integer(),
          expires_at: integer()
        }

  @typedoc "Anything this cache can hold."
  @type cached :: entry() | marking_entry() | unresolvable_entry()

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
    # `update_element/3` rewrites an EXISTING row and never creates one. A bare
    # insert RESURRECTED a row that a concurrent `delete/3`, sweep or
    # `invalidate_local/1` had removed between the lookup above and this write —
    # back into a table an invalidation had just cleared, and invisible to the
    # resident counter, so the tenant silently gained headroom over its share.
    _ = :ets.update_element(@table, key, {2, used})
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

  `opts[:ttl_ms]` overrides the hard TTL for this entry. Used by the NEGATIVE
  cache (`Loopctl.Egress.Policy`), which must remember "this host did not resolve"
  for far less time than a successful classification — long enough to collapse a
  burst of lookups, short enough that recovery from a resolver blip is prompt.

  The ENTRY IS BUILT ONCE AND RETURNED ON EVERY PATH, including the one where the
  ETS table is unavailable (owner mid-restart) and nothing is stored. A cache
  being down must degrade to a CACHE MISS, never to a different answer: the
  storage failure used to be rescued around the whole body and returned a
  DIFFERENTLY SHAPED map (no `:host`, `:tenant_id`, `:scope_key`, `:expires_at`),
  so the value a caller got back depended on whether the table happened to exist.
  A caller reading a dropped key off that map gets a `KeyError` — a cache
  availability problem surfacing as a classification failure, which for a
  `local_only` scope is a permanent-looking refusal. Storage is therefore the
  only thing the rescue covers.
  """
  @spec put(Ecto.UUID.t(), String.t(), key_host(), map(), keyword()) :: cached()
  def put(tenant_id, scope_key, host, attrs, opts \\ []) do
    now = now_ms()
    ttl = Keyword.get(opts, :ttl_ms, @ttl_ms)

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
        #
        # `min/2` keeps a short-TTL entry from being scheduled for a refresh it
        # would never live to see.
        refresh_at: Map.get(attrs, :refresh_at) || now + min(jittered_refresh_ms(), ttl),
        expires_at: Map.get(attrs, :expires_at) || now + ttl
      })

    _ = store({tenant_id, scope_key, host}, entry, tenant_id, Keyword.get(opts, :generation))

    entry
  end

  # The ONLY part of `put/5` that may fail on cache availability, and the only
  # part the rescue covers. Returns `:ok` either way — the caller's answer is the
  # entry it built, not whether it landed.
  defp store(key, entry, tenant_id, generation) do
    # Membership decides ADMISSION only (an existing key is always re-writable).
    # The counter delta comes from `insert_new/2`, which reports whether THIS
    # write actually created the row: two concurrent first-puts of the same key
    # both read `existing? == false`, so bumping off that read counted one row
    # twice and permanently deducted a slot from the tenant's share.
    existing? = :ets.member(@table, key)

    if admit?(key, entry, existing?, generation, tenant_id) do
      if :ets.insert_new(@table, {key, entry}) do
        bump_count(counter_kind(key, entry), tenant_id, 1)
      else
        :ets.insert(@table, {key, entry})
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # A write is admitted when (a) the caller's captured generation is still current,
  # (b) it does not grow the table past the hard global cap and (c) it does not
  # grow THIS TENANT past its share of it.
  defp admit?(key, entry, existing?, generation, tenant_id) do
    cond do
      stale_generation?(tenant_id, generation) -> false
      existing? -> true
      tenant_capped?(key, entry, tenant_id) -> log_tenant_capacity_drop(key, entry, tenant_id)
      :ets.info(@table, :size) < @max_entries -> true
      true -> log_capacity_drop(key)
    end
  end

  # The three shapes in this table grow for different reasons, so each spends its
  # OWN budget. Counting them against one shared counter let a run of DNS misses
  # starve a tenant's real pins; exempting them from the CHECK while still counting
  # them did BOTH — the exempt rows spent the pin budget AND no per-tenant bound
  # held them, so one tenant could reach the shared global cap with the cheapest
  # row it can produce.
  defp tenant_capped?(key, entry, tenant_id) do
    kind = counter_kind(key, entry)

    case tenant_cap(kind) do
      :unbounded -> false
      cap -> count(kind, tenant_id) >= cap
    end
  end

  defp counter_kind({_tenant_id, _scope_key, host}, entry) do
    cond do
      not is_binary(host) -> :marking_resident
      Map.get(entry, :base_verdict) == :unresolvable -> :negative_resident
      true -> :resident
    end
  end

  defp tenant_cap(:resident), do: @max_entries_per_tenant
  defp tenant_cap(:negative_resident), do: @max_negative_entries_per_tenant

  # A scope's `:__marking__` is ONE row per scope, and a scope is a `role: :user`
  # gated record — a tenant cannot inflate markings by request volume the way it
  # inflates hosts, so a per-tenant bound would only ever fire on a legitimately
  # large tenant and cost it a DB read on EVERY classification. The GLOBAL cap
  # still bounds them.
  defp tenant_cap(:marking_resident), do: :unbounded

  defp log_capacity_drop(key) do
    Logger.warning(
      "Loopctl.Egress.PinCache: at capacity (#{@max_entries} entries); not admitting " <>
        "#{inspect(elem(key, 2))} — it will be re-classified on demand"
    )

    false
  end

  defp log_tenant_capacity_drop(key, entry, tenant_id) do
    kind = counter_kind(key, entry)

    Logger.warning(
      "Loopctl.Egress.PinCache: tenant at capacity (#{tenant_cap(kind)} #{kind} entries) " <>
        "tenant_id=#{tenant_id}; not admitting #{inspect(elem(key, 2))} — it will be " <>
        "re-classified on demand"
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

  @doc """
  How many PINS this tenant currently holds — the value `@max_entries_per_tenant`
  bounds. Markings and negative entries are counted separately
  (`aux_resident/1`), because they are bounded separately.

  A COUNTER rather than a `match`/`select_count` over the pin table: `admit?/3`
  runs on the classification hot path, and scanning a 50k-entry table per put is
  exactly the cost this cache exists to avoid. Both counters live in the
  generations table under `{kind, tenant_id}` keys, which cannot collide with the
  bare-binary generation keys.

  They are maintained incrementally (admit +1, `delete/3` -1 clamped at 0,
  `invalidate_local/1` resets to 0) AND reconciled to the true count at the end of
  every refresh pass, so a counter that drifts — an owner restart takes the pin
  table with it but not the counters — self-corrects within one tick instead of
  wedging the tenant's admissions permanently.
  """
  @spec resident(Ecto.UUID.t()) :: non_neg_integer()
  def resident(tenant_id), do: count(:resident, tenant_id)

  @doc "How many NEGATIVE (`:unresolvable`) entries this tenant holds — its own budget."
  @spec negative_resident(Ecto.UUID.t()) :: non_neg_integer()
  def negative_resident(tenant_id), do: count(:negative_resident, tenant_id)

  @doc "How many scope MARKINGS this tenant holds (bounded globally, not per tenant)."
  @spec marking_resident(Ecto.UUID.t()) :: non_neg_integer()
  def marking_resident(tenant_id), do: count(:marking_resident, tenant_id)

  @counter_kinds [:resident, :negative_resident, :marking_resident]

  defp count(kind, tenant_id) do
    case :ets.lookup(@gen_table, {kind, tenant_id}) do
      [{_key, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp bump_count(_kind, _tenant_id, 0), do: :ok

  defp bump_count(kind, tenant_id, delta) when delta > 0 do
    key = {kind, tenant_id}
    _ = :ets.update_counter(@gen_table, key, {2, delta}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp bump_count(kind, tenant_id, delta) do
    key = {kind, tenant_id}
    # `{Pos, Incr, Threshold, SetValue}` clamps at 0: a delete of an already-absent
    # key must never drive the counter negative and hand the tenant free headroom.
    _ = :ets.update_counter(@gen_table, key, {2, delta, 0, 0}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp reset_counts(tenant_id) do
    Enum.each(@counter_kinds, &:ets.insert(@gen_table, {{&1, tenant_id}, 0}))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops one entry (the re-pin primitive — no role `:user` write required)."
  @spec delete(Ecto.UUID.t(), String.t(), key_host()) :: :ok
  def delete(tenant_id, scope_key, host) do
    # `take/2` reads and deletes in ONE op, so the resident counter is only
    # decremented when a row actually went away — a delete of an absent key must
    # not hand the tenant headroom it never used.
    case :ets.take(@table, {tenant_id, scope_key, host}) do
      [{key, entry}] -> bump_count(counter_kind(key, entry), tenant_id, -1)
      _ -> :ok
    end
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
    # Every one of the tenant's rows just went away, so both counters are exactly
    # 0. Leaving them at their pre-invalidation value would keep the tenant locked
    # out of its own (now empty) share until the next refresh reconcile.
    reset_counts(tenant_id)
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

  @doc false
  def max_entries_per_tenant, do: @max_entries_per_tenant

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
    reconcile_resident(tenant_filter)

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

  # Re-anchor the per-tenant resident counters to the TRUE post-sweep count. The
  # incremental maintenance in `store/4` / `delete/3` is what the hot path relies
  # on; this is the correction that stops a drift from becoming permanent — an
  # owner restart drops the pin table but NOT the generations table, which would
  # otherwise leave every tenant reading a resident count for entries that no
  # longer exist and refusing admissions forever.
  #
  # A tenant-SCOPED pass touches only its own counter: the shared table means an
  # `async: true` test running a scoped pass must not rewrite a neighbour's.
  #
  # The true count is read from the table AT RECONCILE TIME and applied as a
  # DELTA, never as an absolute overwrite of the snapshot the pass opened with:
  # the delete phase runs in between, and every concurrent `store/4` that bumped
  # the counter inside that window had its increment discarded — so a tenant
  # writing during a sweep could hold more rows than the share this counter
  # bounds. The COUNTERS are read BEFORE the table, so a store landing between the
  # two reads appears in both and its increment survives the delta; a store
  # landing outside that ordering is corrected on the next pass rather than
  # silently discarded. Tenants with a counter but NO live entry are re-anchored
  # too: an absolute set derived from the live rows never mentioned them, so a
  # drifted-high counter on an empty table deducted their headroom forever.
  defp reconcile_resident(:all) do
    apply_deltas(counter_snapshot(counted_keys()), Enum.frequencies(counter_keys(:all)))
  end

  defp reconcile_resident(tenant_id) do
    keys = Enum.map(@counter_kinds, &{&1, tenant_id})
    apply_deltas(counter_snapshot(keys), Enum.frequencies(counter_keys(tenant_id)))
  end

  defp counter_snapshot(keys), do: Map.new(keys, fn {kind, t} = key -> {key, count(kind, t)} end)

  defp apply_deltas(before, counts) do
    (Map.keys(counts) ++ Map.keys(before))
    |> Enum.uniq()
    |> Enum.each(fn {kind, tenant_id} = key ->
      bump_count(kind, tenant_id, Map.get(counts, key, 0) - Map.get(before, key, 0))
    end)
  end

  # ONE pass that classifies every row into the counter key it spends, selecting
  # only what it needs so a reconcile never materialises 50k entry maps the way
  # `all/0` does. Clauses are tried in order, mirroring `counter_kind/2`: PINS
  # first (binary host, verdict not `:unresolvable`), then NEGATIVE entries, then
  # everything else — a marking, whose atom host fails `is_binary/1`.
  defp counter_keys(:all), do: select_counter_keys({:"$1", :_, :"$2"}, :"$1")
  defp counter_keys(tenant_id), do: select_counter_keys({tenant_id, :_, :"$2"}, tenant_id)

  defp select_counter_keys(key_pattern, tenant) do
    :ets.select(@table, [
      {{key_pattern, :"$3"},
       [{:is_binary, :"$2"}, {:"/=", {:map_get, :base_verdict, :"$3"}, :unresolvable}],
       [{{:resident, tenant}}]},
      {{key_pattern, :"$3"},
       [{:is_binary, :"$2"}, {:==, {:map_get, :base_verdict, :"$3"}, :unresolvable}],
       [{{:negative_resident, tenant}}]},
      {{key_pattern, :_}, [], [{{:marking_resident, tenant}}]}
    ])
  rescue
    ArgumentError -> []
  end

  defp counted_keys do
    :ets.select(@gen_table, [
      {{{:"$1", :"$2"}, :_}, [{:is_atom, :"$1"}], [{{:"$1", :"$2"}}]}
    ])
  rescue
    ArgumentError -> []
  end

  # `update_element/3` for the same reason `mark_used/2` uses it: a row swept or
  # invalidated between the read and the write must stay gone.
  defp clear_used(entry) do
    key = {entry.tenant_id, entry.scope_key, entry.host}

    case :ets.lookup(@table, key) do
      [{^key, current}] -> :ets.update_element(@table, key, {2, Map.put(current, :used, false)})
      [] -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # `:unresolvable` (the NEGATIVE cache) is skipped for the same reason
  # `:denylisted` is: there is no pin to revalidate, and its short TTL means it
  # expires long before it could ever be due anyway.
  defp refreshable?(entry, now) do
    is_binary(entry.host) and now >= entry.refresh_at and not entry.pin_stale and
      Map.get(entry, :base_verdict) not in [:denylisted, :unresolvable]
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
    # `update_element/3` covers the row-already-gone case in the same op.
    if not stale_generation?(entry.tenant_id, generation) do
      :ets.update_element(@table, key, {2, Map.put(entry, :state, :revalidating)})
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
