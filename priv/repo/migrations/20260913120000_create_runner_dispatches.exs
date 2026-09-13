defmodule Loopctl.Repo.Migrations.CreateRunnerDispatches do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Issue #803: the dispatch ledger.
  #
  # `Loopctl.Runners.dispatch/3` used to broadcast and forget. A dispatch is an outward side
  # effect — a prompt a machine executes as its user — so its identity is written HERE before
  # the broadcast, and a second dispatch with the same `dispatch_id` finds the row instead of
  # creating another (design §3: write the side effect's identity before acting, check it on
  # entry).
  #
  # The runner's `dispatch_reply` moves the row out of `sent` exactly once. The first trace
  # batch of the accepted run binds `run_id`, and `trace_acked_seq` is the run's contiguous
  # trace cursor, advanced in the same transaction that stores the events.
  #
  # `story_id` carries no foreign key on purpose: the ledger records what was SENT, and a
  # story deleted later must not take the record of its dispatch with it. The tenant cascade
  # still removes everything.
  def change do
    create table(:runner_dispatches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :dispatch_id, :binary_id, null: false
      add :story_id, :binary_id, null: false
      add :claim_epoch, :bigint, null: false
      add :kind, :text, null: false
      add :status, :text, null: false, default: "sent"
      add :reason, :text, null: true
      add :reason_detail, :text, null: true
      add :replied_at, :utc_datetime_usec, null: true
      add :run_id, :binary_id, null: true
      add :trace_acked_seq, :bigint, null: false, default: -1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runner_dispatches, [:tenant_id, :dispatch_id],
             name: :runner_dispatches_tenant_dispatch_uidx
           )

    # A run belongs to ONE dispatch. The trace cursor is looked up by it.
    create unique_index(:runner_dispatches, [:tenant_id, :run_id],
             where: "run_id IS NOT NULL",
             name: :runner_dispatches_tenant_run_uidx
           )

    create index(:runner_dispatches, [:tenant_id, :runner_id])

    create constraint(:runner_dispatches, :runner_dispatches_status,
             check: "status IN ('sent', 'accepted', 'refused', 'superseded')"
           )

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement')"
           )

    create constraint(:runner_dispatches, :runner_dispatches_claim_epoch,
             check: "claim_epoch >= 0"
           )

    # A refusal always says why; nothing else carries a reason.
    create constraint(:runner_dispatches, :runner_dispatches_reason_iff_refused,
             check: "(status = 'refused') = (reason IS NOT NULL)"
           )

    # Only an accepted dispatch runs, so only an accepted one has a run or a trace cursor.
    create constraint(:runner_dispatches, :runner_dispatches_run_requires_accepted,
             check: "run_id IS NULL OR status IN ('accepted', 'superseded')"
           )

    enable_rls(:runner_dispatches)
  end
end
