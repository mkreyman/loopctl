defmodule Loopctl.AuditChain.SthEnqueuer do
  @moduledoc """
  US-35.2 — Event-driven, activity-gated STH enqueuer.

  A supervised, CLUSTER-WIDE singleton GenServer that subscribes to the fixed
  cross-tenant audit-chain firehose topic (`Loopctl.AuditChain.PubSub`) and, on
  each `{:audit_chain_entry, entry}` message, debounce-enqueues one
  `Loopctl.Workers.ComputeSthWorker` job for `entry.tenant_id`. This makes STH
  computation react to real append activity instead of relying solely on the
  per-minute `all_tenants` cron. The firehose message is a MINIMAL
  `%{tenant_id: _}` map (not the full `%Entry{}`) — `tenant_id` is the only field
  this subscriber reads, so nothing else needs to cross the shared topic.

  ## Cluster singleton with real failover (US-38.3, AC-38.3.1)

  Across N clustered nodes EXACTLY ONE instance actually subscribes to and drains
  the firehose. Before this, every node subscribed and enqueued, so an append
  fanned out to all N nodes did N redundant `Oban.insert/2` calls (safe — Oban
  `unique` dedups them — but N× wasteful work on the DB); with a single
  cluster-wide drainer the firehose is consumed once. On a SINGLE node behavior is
  byte-for-byte unchanged: that one node wins leadership and is the singleton,
  subscribing and enqueuing exactly as before.

  ### How leadership + failover work (self-hosted Starter+Monitor, no `:ignore`)

  EVERY node's supervisor keeps a `SthEnqueuer` process ALIVE — there is no
  `:ignore`, so no node is ever left without a live process. `start_link/1` always
  returns `{:ok, pid}` (a plain, node-local start); leadership is then negotiated
  IN `init` (via `handle_continue/2`, keeping `init` light), not by the registered
  name of `start_link`. Each `:singleton`-mode instance calls
  `:global.register_name(leadership_key, self())`:

    * `:yes` → it is the **leader**: it subscribes to the firehose and drains it.
    * `:no`  → another node holds leadership, so it becomes a **standby**: it
      `Process.monitor/1`s the current holder (a cross-node monitor) and does
      NOT subscribe. It sits idle but ALIVE.

  When the leader — or its whole node — goes down, `:global` frees the name
  cluster-wide and every standby's monitor fires `{:DOWN, ...}`. On that message a
  standby re-runs the registration: exactly one wins and becomes the new leader
  (subscribing and resuming the drain); the rest re-monitor the new holder. THIS
  is the failover AC-38.3.1 requires — a surviving node's standby takes over, not
  merely the same-node process-crash case. A brief `:retry_leadership` timer
  covers the race where the old holder's name has not yet been freed at the moment
  a standby retries. Correctness is additionally backstopped by the idempotent
  per-minute `ComputeSthWorker` cron (below), so any sub-second takeover gap only
  defers an activity-driven enqueue to the next cron tick — never data loss.

  ## Mode / test seam — explicit `:name` opt yields a plain LOCAL standalone

  Two modes, resolved from opts in `start_link/1`:

    * `:singleton` (the app-boot default: no `:name`, or an explicit
      `:leadership_key`) — the global-leadership + standby/failover behavior above,
      keyed on `leadership_key` (default `__MODULE__`).
    * `:standalone` (an explicit `:name` with no `:leadership_key`) — an ordinary
      node-local instance that is always active and subscribes per `:subscribe`.
      This preserves the async-suite seam: the US-35.2 tests start isolated,
      always-subscribing instances via `start_supervised!` without contending on
      the one global leadership name.

  Failover itself is driven directly by starting TWO `:singleton`-mode instances
  under one isolated `leadership_key`, asserting exactly one leads, killing it, and
  asserting the standby takes over (see the test module).

  ## Why a GenServer (OTP Iron Law)

  It owns a durable PubSub subscription that must persist for the node's lifetime
  and survive the transient request/Task/Oban process that produced an append —
  a stable subscriber is exactly the "mutable state persisting across calls +
  fault isolation" case a process is for. It holds NO per-tenant state (see
  below), never sits on a hot read path, and does one cheap `Oban.insert/2` per
  message.

  ## Debounce / coalescing is Oban-`unique`, not GenServer state

  All burst-coalescing lives in the DB via Oban's `unique` option, NOT in this
  process. Each enqueue is a single `Oban.insert/2` (NOT `insert_all/1`, which is
  inert for `unique` on the Basic Engine — see `ComputeSthWorker` moduledoc) with
  `unique: [fields: [:worker, :args], period: …, states: [:available,
  :scheduled]]` and a short `schedule_in` debounce. A burst of appends for one
  tenant within the window therefore collapses to a SINGLE scheduled job at the
  DB level. Because the dedup is in Postgres, this is both burst-safe on one node
  AND multi-node safe: with the firehose delivered to every node, each node's
  enqueuer may insert, but `unique` lets at most one job per tenant per window
  survive. Consequently this GenServer holds no per-tenant map that could grow
  without bound — its state is a minimal, fixed map.

  ## Resilience (fire-and-forget)

  The append path broadcasts to the firehose fire-and-forget, so this process can
  never crash an append. In turn, `handle_info/2` classifies every message so the
  process stays alive across all of them:

    * a genuine enqueue fault on a well-formed entry — an Oban `{:error, _}` tuple
      (WARNING), a RAISE (rescued, ERROR "crashed"), or an :exit/throw (caught,
      ERROR) — is logged and swallowed;
    * a correctly-shaped but MALFORMED entry (no binary `tenant_id`) is logged at
      WARNING and ignored (never the ERROR/"crashed" path, which is reserved for
      real faults);
    * any unknown-shape message is logged at DEBUG and ignored.

  Correctness is preserved even if this enqueuer is down or misses events,
  because the per-minute cron poll (unchanged by this story) still runs and the
  per-tenant `ComputeSthWorker.perform/1` clause is idempotent
  (`AuditChain.sth_needed?/1`-gated).
  """

  use GenServer

  require Logger

  alias Loopctl.AuditChain.PubSub, as: ChainPubSub
  alias Loopctl.Workers.ComputeSthWorker

  # Default debounce (seconds). Config-driven per CLAUDE.md DI rules — read at
  # runtime via Application.get_env/3, never Application.put_env in tests.
  @default_debounce_seconds 5

  # Fallback delay (ms) before a standby re-attempts leadership when it lost the
  # register race but the current holder had already vanished (so there was no pid
  # to monitor). Config-driven per the DI rules; kept short — this only covers a
  # narrow transient window, steady state is monitor-driven.
  @default_leadership_retry_ms 200

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # ALWAYS a plain node-local start (never `:ignore`) so every node keeps a live
    # process that can lead OR stand by. Leadership is negotiated in `init` via
    # `:global.register_name/2`, not by the registered name here. An explicit
    # `:name` (a per-test unique atom) is honored for local addressing.
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  The debounce window (seconds), read at runtime from application config.

  Drives BOTH the job's `schedule_in` and the Oban `unique` `period`, so a burst
  of appends for one tenant within this window collapses to a single scheduled
  `ComputeSthWorker` job.
  """
  @spec debounce_seconds() :: pos_integer()
  def debounce_seconds do
    Application.get_env(:loopctl, :sth_enqueuer_debounce_seconds, @default_debounce_seconds)
  end

  @doc """
  Enqueues a single debounced `ComputeSthWorker` job for `entry.tenant_id`.

  Exposed (rather than kept private in `handle_info/2`) so tests can drive the
  exact enqueue path directly from the test process — where the Ecto Sandbox
  connection and Oban testing mode apply — without racing the separate GenServer
  process. Returns the raw `Oban.insert/2` result.

  Builds the job with a short `schedule_in` debounce and the Basic-Engine-honored
  `unique: [fields: [:worker, :args], period: …, states: [:available,
  :scheduled]]` so bursts coalesce at the DB. String arg keys per the Oban
  JSON-serialization Iron Law.
  """
  @spec enqueue_sth_job(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_sth_job(%{tenant_id: tenant_id}) when is_binary(tenant_id) do
    debounce = debounce_seconds()

    %{"tenant_id" => tenant_id}
    |> ComputeSthWorker.new(
      schedule_in: debounce,
      unique: [
        fields: [:worker, :args],
        period: debounce,
        states: [:available, :scheduled]
      ]
    )
    |> Oban.insert()
  end

  @doc """
  Fallback leadership-retry delay (ms), read at runtime from application config.

  Only used by a standby that lost the register race to a holder that had already
  vanished (no pid to monitor) — a rare transient. Steady-state takeover is
  monitor-driven, not timer-driven.
  """
  @spec leadership_retry_ms() :: pos_integer()
  def leadership_retry_ms do
    Application.get_env(
      :loopctl,
      :sth_enqueuer_leadership_retry_ms,
      @default_leadership_retry_ms
    )
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    # Subscription is config-gated (default ON) so the app's boot singleton can be
    # kept from reacting under the Ecto Sandbox in the test suite — where its
    # `Oban.insert` would run without an owned connection — while production always
    # subscribes. Tests that need a LIVE subscriber start their OWN instance with
    # `subscribe: true`, and the config default stays true so the production
    # supervision-tree child subscribes normally.
    subscribe? =
      Keyword.get(
        opts,
        :subscribe,
        Application.get_env(:loopctl, :sth_enqueuer_subscribe, true)
      )

    # Mode resolution (see moduledoc): an explicit `:leadership_key` opts into
    # :singleton with a contendable/isolated key (used by failover tests); an
    # explicit `:name` with no key is the local :standalone seam; the bare
    # app-boot default is :singleton keyed on `__MODULE__`.
    leadership_key = Keyword.get(opts, :leadership_key)

    mode =
      cond do
        not is_nil(leadership_key) -> :singleton
        Keyword.has_key?(opts, :name) -> :standalone
        true -> :singleton
      end

    state = %{
      mode: mode,
      leadership_key: leadership_key || __MODULE__,
      subscribe?: subscribe?,
      role: :starting,
      leader_ref: nil
    }

    # Negotiate leadership in handle_continue to keep init lightweight (cluster
    # init should not block on :global). Phoenix.PubSub starts strictly before
    # this owner in the tree, so subscribing from the continue is safe.
    {:ok, state, {:continue, :establish_role}}
  end

  # :standalone — always the active drainer for its local scope; no global
  # leadership, no standby. Preserves the async-suite seam.
  @impl true
  def handle_continue(:establish_role, %{mode: :standalone} = state) do
    if state.subscribe?, do: ChainPubSub.subscribe_firehose()
    {:noreply, %{state | role: :leader}}
  end

  # :singleton — contend for cluster-wide leadership; lead (subscribe) or stand by.
  @impl true
  def handle_continue(:establish_role, %{mode: :singleton} = state) do
    {:noreply, try_become_leader(state)}
  end

  # The monitored leader (its process, or its whole node) went down. `:global` has
  # freed the leadership name cluster-wide, so re-contend: exactly one surviving
  # standby wins and becomes the new drainer (real failover, AC-38.3.1); the rest
  # re-monitor the new holder.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{leader_ref: ref} = state) do
    Logger.info(
      "SthEnqueuer: observed leader down; attempting cluster-singleton takeover " <>
        "(#{inspect(state.leadership_key)})"
    )

    {:noreply, try_become_leader(%{state | leader_ref: nil})}
  end

  # Fallback retry for the narrow race where a standby lost the register but the
  # holder had already vanished (nothing to monitor). Only meaningful while still a
  # standby singleton — otherwise a stale timer is a no-op.
  @impl true
  def handle_info(:retry_leadership, %{mode: :singleton, role: :standby} = state) do
    {:noreply, try_become_leader(state)}
  end

  def handle_info(:retry_leadership, state), do: {:noreply, state}

  @impl true
  def handle_info({:audit_chain_entry, %{tenant_id: tenant_id} = entry}, state)
      when is_binary(tenant_id) do
    # Well-formed entry. The enqueue is wrapped so NO failure mode can crash the
    # subscriber (AC-35.2.5): an Oban `{:error, _}` tuple is logged at WARNING; a
    # RAISE (transient DB/pool fault, serialization error) is rescued; and an
    # :exit or throw surfacing from the enqueue path (e.g. a checkout/GenServer
    # timeout raised as an exit) is caught. Correctness is backstopped by the
    # idempotent per-minute cron poll, so swallowing here only trades a missed
    # activity-driven enqueue for a slightly later cron-driven one.
    try do
      case enqueue_sth_job(entry) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("SthEnqueuer: failed to enqueue ComputeSthWorker: #{inspect(reason)}")
      end
    rescue
      error ->
        Logger.error(
          "SthEnqueuer: crashed while enqueuing ComputeSthWorker (ignored): " <>
            Exception.message(error)
        )
    catch
      kind, reason ->
        # :exit / throw from the enqueue path — never let it kill the singleton.
        Logger.error(
          "SthEnqueuer: caught #{kind} while enqueuing ComputeSthWorker (ignored): " <>
            inspect(reason)
        )
    end

    {:noreply, state}
  end

  # A correctly-shaped firehose message whose entry carries no binary tenant_id is
  # MALFORMED but benign (AC-35.2.5). Audit entries always carry a binary
  # tenant_id in practice, so this indicates upstream corruption — not an enqueue
  # fault. Log at WARNING (never ERROR/"crashed", which is reserved for genuine
  # enqueue faults in the clause above) and ignore. Never raise/crash.
  @impl true
  def handle_info({:audit_chain_entry, malformed}, state) do
    Logger.warning(
      "SthEnqueuer: ignoring malformed audit_chain_entry (no binary tenant_id): " <>
        inspect(malformed)
    )

    {:noreply, state}
  end

  # Any other (unknown-shape) message is logged at DEBUG and ignored (AC-35.2.5).
  @impl true
  def handle_info(msg, state) do
    Logger.debug("SthEnqueuer: ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Leadership (cluster singleton) ---

  # Attempt to claim the cluster-wide leadership name. On success we are the sole
  # drainer and subscribe; on failure we become a monitoring standby ready to take
  # over. Called both at boot (establish_role) and on takeover (leader :DOWN).
  defp try_become_leader(state) do
    case :global.register_name(state.leadership_key, self()) do
      :yes ->
        if state.subscribe?, do: ChainPubSub.subscribe_firehose()

        Logger.info(
          "SthEnqueuer: acquired cluster-singleton leadership (#{inspect(state.leadership_key)})"
        )

        %{state | role: :leader, leader_ref: nil}

      :no ->
        become_standby(state)
    end
  end

  # Lost (or did not attempt) leadership: monitor the current holder so its death
  # triggers failover. If the holder already vanished (undefined) or somehow is us,
  # fall back to a short retry / self-promotion rather than monitoring a ghost.
  defp become_standby(state) do
    case :global.whereis_name(state.leadership_key) do
      :undefined ->
        Process.send_after(self(), :retry_leadership, leadership_retry_ms())
        %{state | role: :standby, leader_ref: nil}

      leader_pid when leader_pid == self() ->
        %{state | role: :leader, leader_ref: nil}

      leader_pid ->
        ref = Process.monitor(leader_pid)
        %{state | role: :standby, leader_ref: ref}
    end
  end
end
