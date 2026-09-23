defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesSessionEnded do
  @moduledoc """
  Why an implement session ended, as its runner reported it (epic 44, US-44.3; runner contract
  1.16.0). One report per dispatch, so it lives on the dispatch's own ledger row rather than in
  a table of its own: the row is already the idempotency key for everything else a runner says
  about that dispatch, and the unique `(tenant_id, dispatch_id)` it carries is what makes
  "recorded once" a property of the storage rather than of the code.

  - `session_ended_reason` — the runner's `reason`, one of the contract's enum.
  - `session_ended_digest` — a sha256 over the canonical message. A byte-identical resend is
    answered `ok` and a DIFFERENT one is refused `already_recorded`, and this is what decides
    which it is. It is compared BEFORE the claim-epoch fence, because a `crashed` report bumps
    the epoch and an honest resend of it must still be answered `ok`.
  - `session_ended_at` — when the FIRST copy was recorded.
  - `counts_toward_retry_ceiling` — for the two reasons that re-queue the story, whether that
    release is spent against the retry ceiling (US-44.4 builds the ceiling). `crashed` is a
    counted attempt; `usage_exhausted` is not, because the subscription ran out and the work
    was never judged. NULL for every other reason — a budget kill ends the claim too, but its
    story is escalated, never retried.

  All four are set together or not at all, and the CHECKs hold that at the database, so a
  writer that bypassed `Loopctl.Runners.DispatchLedger` cannot leave a digest with no reason
  (which would refuse every resend `already_recorded` against nothing) or a counted flag on a
  report that re-queued nothing, or on no report at all.

  No backfill and no manual step: every existing row starts NULL, which reads as "no session
  end reported", exactly what those rows are. Additive and nullable, so an old instance still
  serving during the rolling deploy writes rows the new code reads correctly.
  """

  use Ecto.Migration

  @reasons ~w(completed wall_clock_exceeded max_turns_exceeded usage_exhausted crashed)
  @releasing ~w(crashed usage_exhausted)

  def up do
    alter table(:runner_dispatches) do
      add :session_ended_reason, :string, null: true
      add :session_ended_digest, :string, null: true
      add :session_ended_at, :utc_datetime_usec, null: true
      add :counts_toward_retry_ceiling, :boolean, null: true
    end

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_session_ended_reason
      CHECK (session_ended_reason IS NULL OR session_ended_reason IN (#{quoted(@reasons)}))
    """)

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_session_ended_together
      CHECK (
        (session_ended_reason IS NULL) = (session_ended_digest IS NULL)
        AND (session_ended_reason IS NULL) = (session_ended_at IS NULL)
      )
    """)

    # COALESCE, because `NULL IN (...)` is NULL and a CHECK that evaluates NULL PASSES: without
    # it a row with no reason could carry a counted flag, which is exactly what this forbids.
    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_session_ended_counted
      CHECK (
        COALESCE(session_ended_reason IN (#{quoted(@releasing)}), false)
          = (counts_toward_retry_ceiling IS NOT NULL)
      )
    """)
  end

  def down do
    execute(
      "ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_session_ended_counted"
    )

    execute(
      "ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_session_ended_together"
    )

    execute(
      "ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_session_ended_reason"
    )

    alter table(:runner_dispatches) do
      remove :session_ended_reason
      remove :session_ended_digest
      remove :session_ended_at
      remove :counts_toward_retry_ceiling
    end
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
