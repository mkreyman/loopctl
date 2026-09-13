defmodule Loopctl.Repo.Migrations.CreateRunnerTraceEvents do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Issue #803: trace intake (design §11).
  #
  # One row per event of a run's NDJSON trace, as the runner ships it. The on-disk file is
  # the source of truth; this table is a copy the runner resumes into after every rejoin, so
  # `(tenant_id, run_id, seq)` is UNIQUE and inserts are `ON CONFLICT DO NOTHING`: a batch
  # sent twice is stored once.
  #
  # NOT the audit chain. The chain serialises every writer on the tenant's latest entry, and
  # a trace is high-volume observability, not a custody transition.
  #
  # Retention is not here yet: a prune worker belongs in `oban_config.ex`. The foreign key to
  # the ledger row cascades, so pruning a dispatch record prunes its trace.
  def change do
    create table(:runner_trace_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :runner_dispatch_id,
          references(:runner_dispatches, type: :binary_id, on_delete: :delete_all),
          null: false

      add :run_id, :binary_id, null: false
      add :seq, :bigint, null: false
      add :event_id, :text, null: false
      add :parent, :text, null: true
      add :ts, :utc_datetime_usec, null: false
      add :type, :text, null: false
      add :data, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # The dedup key, and the index the contiguous-ack query walks.
    create unique_index(:runner_trace_events, [:tenant_id, :run_id, :seq],
             name: :runner_trace_events_tenant_run_seq_uidx
           )

    create index(:runner_trace_events, [:runner_dispatch_id])

    # Below bigint's maximum, so the contiguous-ack query's `seq + 1` can never overflow.
    create constraint(:runner_trace_events, :runner_trace_events_seq,
             check: "seq >= 0 AND seq < 9223372036854775807"
           )

    enable_rls(:runner_trace_events)
  end
end
