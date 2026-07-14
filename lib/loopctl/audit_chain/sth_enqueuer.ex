defmodule Loopctl.AuditChain.SthEnqueuer do
  @moduledoc """
  US-35.2 — Event-driven, activity-gated STH enqueuer.

  A supervised, node-local singleton GenServer that subscribes to the fixed
  cross-tenant audit-chain firehose topic (`Loopctl.AuditChain.PubSub`) and, on
  each `{:audit_chain_entry, entry}` message, debounce-enqueues one
  `Loopctl.Workers.ComputeSthWorker` job for `entry.tenant_id`. This makes STH
  computation react to real append activity instead of relying solely on the
  per-minute `all_tenants` cron.

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

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    # Subscribe to the fixed cross-tenant firehose so we observe every tenant's
    # appends through ONE subscription. `Phoenix.PubSub` starts strictly before
    # this owner in the supervision tree, so the subscribe here is safe.
    #
    # Subscription is config-gated (default ON) so the app's boot singleton can
    # be kept from reacting under the Ecto Sandbox in the test suite — where its
    # `Oban.insert` would run without an owned connection — while production
    # always subscribes. Tests that need a LIVE subscriber start their OWN named
    # instance with `subscribe: true`, and the config default stays true so the
    # production supervision-tree child subscribes normally.
    subscribe? =
      Keyword.get(
        opts,
        :subscribe,
        Application.get_env(:loopctl, :sth_enqueuer_subscribe, true)
      )

    if subscribe?, do: ChainPubSub.subscribe_firehose()
    {:ok, %{}}
  end

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
end
