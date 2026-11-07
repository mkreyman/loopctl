defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesTurnsAndWorkLeftBehind do
  @moduledoc """
  What the escalation inbox (US-48.11, AC-48.11.2) and the run-outcome ledger (US-48.12) need
  to say about a run's turns and what it left behind, on the dispatch's own ledger row
  (`runner_dispatches`), from loopctl's records and the runner's session-end report — never
  from session text.

  - `max_turns` — the turn budget the dispatch was PLACED under. Written by
    `Loopctl.Runners.DispatchLedger` wherever `wall_clock_seconds` is: on the first insert,
    then refreshed by the push that wins delivery. A budget the column cannot hold (the
    contract bounds `max_turns` below only) is stored NULL rather than refusing the dispatch.
  - `session_turns_used` — the turns the session took, as the runner reported them in
    `session_ended` (runner contract 1.27.0).
  - `work_left_behind` — the runner's `session_ended` word on whether the session's branch had
    commits not on the remote at exit: true or false; NULL when it could not tell.

  The two session-end columns are written ONCE, by the session-end recording, with the reason
  and digest beside them; a resend never rewrites them. A CHECK holds that neither stands
  without a recorded `session_ended_reason`, so no writer can leave a figure with no report
  behind it. Counts are non-negative and a budget positive, as the contract states them.

  No backfill and no manual step: every existing row starts NULL, which reads as "not
  reported", exactly what those rows are (a 1.26.0 runner sends neither, and no row before this
  carried a turn budget). Additive and nullable, so an old instance still serving during the
  rolling deploy writes rows the new code reads correctly.
  """

  use Ecto.Migration

  def up do
    alter table(:runner_dispatches) do
      add :max_turns, :integer, null: true
      add :session_turns_used, :integer, null: true
      add :work_left_behind, :boolean, null: true
    end

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_max_turns_positive
      CHECK (max_turns IS NULL OR max_turns >= 1)
    """)

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_session_turns_used_nonnegative
      CHECK (session_turns_used IS NULL OR session_turns_used >= 0)
    """)

    execute("""
    ALTER TABLE runner_dispatches
      ADD CONSTRAINT runner_dispatches_session_end_figures_reported
      CHECK (
        session_ended_reason IS NOT NULL
        OR (session_turns_used IS NULL AND work_left_behind IS NULL)
      )
    """)
  end

  def down do
    execute(
      "ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_session_end_figures_reported"
    )

    execute(
      "ALTER TABLE runner_dispatches " <>
        "DROP CONSTRAINT runner_dispatches_session_turns_used_nonnegative"
    )

    execute("ALTER TABLE runner_dispatches DROP CONSTRAINT runner_dispatches_max_turns_positive")

    alter table(:runner_dispatches) do
      remove :max_turns
      remove :session_turns_used
      remove :work_left_behind
    end
  end
end
