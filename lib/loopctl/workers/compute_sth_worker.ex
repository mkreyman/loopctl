defmodule Loopctl.Workers.ComputeSthWorker do
  @moduledoc """
  US-26.1.2 — Computes Signed Tree Heads for tenant audit chains.

  Runs periodically to sign the current state of each tenant's audit chain.
  Idempotent: if no new entries exist since the last STH, does nothing.

  ## Scheduling

  Configured via Oban Cron to run every minute in `all_tenants` mode,
  which fans out individual per-tenant jobs via a single `Oban.insert_all/1`
  batch. Each per-tenant job is scheduled with a small deterministic jitter
  (see `jitter/1`) so the fanout doesn't thundering-herd the `:audit` queue
  and the primary DB at the exact `:00` instant of the cron tick.

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
  alias Loopctl.Tenants.Tenant

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
    |> Oban.insert_all()

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    if AuditChain.sth_needed?(tenant_id) do
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
    else
      :ok
    end
  end

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
