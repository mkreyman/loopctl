defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesAgentResult do
  @moduledoc """
  The result a `:draft` session reported through the generic `agent_result` message (runner
  contract 1.25.0, US-48.8). One result per dispatch, so it lives on the dispatch's own ledger
  row exactly as `session_ended` does (`20260923140000`): the row's unique
  `(tenant_id, dispatch_id)` is what makes "recorded once" a property of the storage.

  - `agent_result` — the result object, already validated against the named spec's
    `result_schema`. SESSION-AUTHORED and untrusted: recorded as data, never executed, and never
    copied into the hash-chained audit log.
  - `agent_result_spec` — `<id>@<version>` of the spec it was validated against, written from
    loopctl's own registry entry rather than from the wire.
  - `agent_result_digest` — a sha256 over the canonical result and spec. A byte-identical
    resend is answered `ok` and a DIFFERENT one `already_recorded`; this decides which.
  - `agent_result_at` — when the FIRST copy was recorded.

  All four are set together or not at all, held by a CHECK, so a writer that bypassed
  `Loopctl.Runners.DispatchLedger` cannot leave a digest with nothing behind it (which would
  refuse every resend `already_recorded`). US-48.12 adds the outcome ledger these feed.

  No backfill and no manual step: every existing row starts NULL, which reads as "no result
  reported", exactly what those rows are. Additive and nullable, so an old instance still
  serving during the rolling deploy writes rows the new code reads correctly.
  """

  use Ecto.Migration

  def up do
    alter table(:runner_dispatches) do
      add :agent_result, :map, null: true
      add :agent_result_spec, :string, null: true
      add :agent_result_digest, :string, null: true
      add :agent_result_at, :utc_datetime_usec, null: true
    end

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_agent_result_together
      CHECK (
        (agent_result IS NULL) = (agent_result_spec IS NULL)
        AND (agent_result IS NULL) = (agent_result_digest IS NULL)
        AND (agent_result IS NULL) = (agent_result_at IS NULL)
      )
    """)

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_agent_result_object
      CHECK (agent_result IS NULL OR jsonb_typeof(agent_result) = 'object')
    """)
  end

  def down do
    execute("ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_agent_result_object")

    execute(
      "ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_agent_result_together"
    )

    alter table(:runner_dispatches) do
      remove :agent_result
      remove :agent_result_spec
      remove :agent_result_digest
      remove :agent_result_at
    end
  end
end
