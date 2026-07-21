defmodule Loopctl.Repo.Migrations.CustodyReviewHardening do
  use Ecto.Migration

  # US-41.7, second review round.
  #
  # 1. `failure_reason` was `:string` — varchar(255) — while
  #    `Custody.mark_batch_failed/3` sliced to 500. The ONLY production caller is
  #    `CustodyPostureAppendWorker` on its FINAL attempt, passing a rendering of
  #    an `AuditChain.append/2` failure (a `%Postgrex.Error{}` or an `Ecto.Multi`
  #    error tuple), which routinely exceeds 255 bytes. `update_all` then raised
  #    INSIDE `perform/1`, so the entries were never marked failed and nothing
  #    reached `GET /custody/failures` — the failure surface broke exactly when it
  #    was needed. Widen to :text; the worker now also writes a STABLE CODE plus a
  #    correlation id rather than a raw provider/driver string.
  #
  # 2. The pending-claim read looks up the tenant's in-flight flush jobs with
  #    `args->>'tenant_id'`. Oban's stock indexes are on
  #    (state, queue, priority, scheduled_at, id) — nothing supports that
  #    predicate, so on a busy instance every pending-state claim read was a
  #    sequential scan with a per-row jsonb extraction. A tiny PARTIAL expression
  #    index (only the custody flush worker's rows) makes it an index probe.

  def change do
    alter table(:custody_posture_entries) do
      modify :failure_reason, :text, from: :string
    end

    create index(:oban_jobs, ["(args->>'tenant_id')"],
             name: :oban_jobs_custody_flush_tenant_idx,
             where: "worker = 'Loopctl.Workers.CustodyPostureAppendWorker'"
           )
  end
end
