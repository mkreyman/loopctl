defmodule Loopctl.Workers.ComputeSthWorker do
  @moduledoc """
  US-26.1.2 — Computes Signed Tree Heads for tenant audit chains.

  Runs periodically to sign the current state of each tenant's audit chain.
  Idempotent: if no new entries exist since the last STH, does nothing.

  ## Scheduling

  Configured via Oban Cron to run in `all_tenants` mode on a low-frequency,
  config-driven safety-sweep interval (US-35.3, default every 5 minutes via
  `STH_SWEEP_CRON` / `Loopctl.ObanConfig.sth_sweep_cron/0`) — reduced from the
  former per-minute poll now that US-35.2's event-driven enqueuer signs STHs on
  real audit appends. The sweep fans out individual per-tenant jobs via a single
  `Oban.insert_all/1` batch. Each per-tenant job is scheduled with a small
  deterministic jitter (see `jitter/1`) so the fanout doesn't thundering-herd the
  `:audit` queue and the primary DB at the exact `:00` instant of the cron tick,
  and self-gates on `AuditChain.sth_needed?/1` so a slower sweep can only delay
  (never corrupt) an STH.

  ## `unique` does NOT apply to this fanout

  This worker declares `unique: [fields: [:worker, :args], period: 30]`, but
  Oban's bulk insert (`Oban.insert_all/1`, used above for fanout) only honors
  `unique` on the Smart Engine (Oban Pro). On the Basic Engine (what this app
  runs), `unique` is checked by `Oban.insert/2` (single-job inserts) and is
  inert for `insert_all/1` -- see `Oban.insert_all/1`'s own docs. So the
  fanout can, in principle, enqueue duplicate per-tenant jobs; this is safe
  because `perform/1`'s `tenant_id` clause is idempotent via
  `AuditChain.sth_needed?/1` below -- a duplicate job is a cheap no-op, not a
  duplicate STH. Do not rely on `unique` as the dedup mechanism here; if
  stronger duplicate-prevention is ever required, that means adopting the
  Smart Engine or adding an explicit application-level guard, not assuming
  this attribute already provides it.
  """

  use Oban.Worker,
    queue: :audit,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 30]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.HeavyRead.OverloadedError
  alias Loopctl.Tenants.Tenant

  # US-37.5: bounded, jittered snooze (seconds) when a tenant's STH tail read is shed
  # by the per-tenant HeavyRead in-flight gate. Loss-free (no attempt consumed), so a
  # sustained heavy-read burst can never exhaust this worker's max_attempts and DROP a
  # custody-critical STH checkpoint — it is re-attempted once the tenant's heavy-read
  # load subsides (and `sth_needed?/1` re-fires, so nothing is lost meanwhile).
  @overload_snooze_base_seconds 5
  @overload_snooze_jitter_seconds 10

  # US-32.5: bounded jitter window (seconds) spread across the per-minute cron
  # tick, so per-tenant fanout jobs don't all land at the same `:00` instant.
  @jitter_window_seconds 56

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    import Ecto.Query

    tenants =
      from(t in Tenant, where: t.status == :active, select: t.id)
      |> AdminRepo.all()

    tenants
    |> Enum.map(fn tenant_id ->
      __MODULE__.new(%{"tenant_id" => tenant_id}, schedule_in: jitter(tenant_id))
    end)
    # US-32.5 review fix: `Oban.insert_all/1` -> `Repo.insert_all/3` with NO
    # internal chunking (Oban.Engines.Basic.insert_all_jobs/3). Job.to_map/1
    # emits ~10 non-nil columns per job, so one un-chunked INSERT hits
    # Postgres's 65535 bind-parameter limit around ~6.5k active tenants,
    # failing the ENTIRE fanout (zero STHs computed for any tenant that
    # minute) instead of degrading gracefully. Chunking collapses N tenants
    # to ceil(N/5000) round-trips -- still far fewer than the old one-insert-
    # per-tenant loop -- while removing the crash ceiling entirely.
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Oban.insert_all/1)

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    if AuditChain.sth_needed?(tenant_id) do
      sign_tenant(tenant_id)
    else
      :ok
    end
  end

  # `sign_and_store_tree_head/1`'s bounded STH tail read runs through the per-tenant
  # HeavyRead gate (endpoint `:sth_incremental`, default `on_overload: :raise`). Under
  # a tenant's sustained heavy-read burst that read can be SHED, raising
  # `HeavyRead.OverloadedError`. Rescue it here (the only heavy read in this call path)
  # and yield loss-free with `{:snooze, n}` instead of erroring — an errored STH job
  # would retry-churn and could exhaust max_attempts, dropping a custody-critical
  # checkpoint. (An out-of-band DB error still fails normally via the `{:error, _}`
  # tuple below; only the deliberate overload shed is turned into a snooze.)
  defp sign_tenant(tenant_id) do
    case AuditChain.sign_and_store_tree_head(tenant_id) do
      {:ok, sth} ->
        Logger.info(
          "ComputeSthWorker: signed STH for tenant #{tenant_id} at position #{sth.chain_position}"
        )

        :ok

      {:error, :empty_chain} ->
        :ok

      {:error, reason} ->
        Logger.warning("ComputeSthWorker: failed for tenant #{tenant_id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    OverloadedError ->
      Logger.info(
        "ComputeSthWorker: STH read shed (heavy_read_overloaded) for tenant #{tenant_id}; snoozing"
      )

      {:snooze, overload_snooze_seconds()}
  end

  # :rand.uniform(jitter + 1) ∈ 1..jitter+1 → -1 gives 0..jitter (0 when jitter=0).
  defp overload_snooze_seconds do
    @overload_snooze_base_seconds + :rand.uniform(@overload_snooze_jitter_seconds + 1) - 1
  end

  @doc """
  The jitter window (seconds) used by `jitter/1`, exposed so callers (and
  tests) have a single source of truth instead of mirroring the private
  `@jitter_window_seconds` module attribute.
  """
  def jitter_window_seconds, do: @jitter_window_seconds

  # US-32.5 (AC-32.5.2): bounded, deterministic-per-tenant jitter in
  # [0, @jitter_window_seconds - 1] seconds. Deliberately NOT `:rand` at the
  # module level -- a random value here would make the enqueued job's
  # `schedule_in` (and therefore `scheduled_at`) non-reproducible across
  # retries/tests, and would fight `Oban.insert_all/1`'s ability to spread
  # fanout evenly. `:erlang.phash2/1` is stable for a given tenant_id.
  #
  # Note this has nothing to do with the `unique: [fields: [:worker, :args]]`
  # declaration above: that option is inert on this `insert_all/1` fanout
  # path regardless of `scheduled_at` (see the moduledoc). Jitter's actual
  # job is spreading fanout load, not participating in dedup.
  defp jitter(tenant_id), do: rem(:erlang.phash2(tenant_id), @jitter_window_seconds)
end
