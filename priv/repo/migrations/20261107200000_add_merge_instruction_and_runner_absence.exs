defmodule Loopctl.Repo.Migrations.AddMergeInstructionAndRunnerAbsence do
  @moduledoc """
  The pr-route merge (Epic 48, US-48.17): control decides, the runner executes.

  ## `story_stages.merge_instruction`

  `%{"head_sha", "runner_id", "dispatch_id", "sends", "refusals", "sent_at", "outcome"}` — the record that
  control sent the runner holding the claim an instruction to merge THIS head
  (`Loopctl.Delivery.MergeExecution`). It is what makes the instruction once-per-head: the
  merge job reads it before it pushes, and does not push again for the same head until the
  runner has had `MergeExecution.answer_window_seconds/0` to answer. HEAD-KEYED
  (`StageMachine.head_keyed/0`), so a new head is a new instruction and every edge that clears
  the head clears it.

  ## `story_stages.runner_absence`

  `%{"runner_id", "since"}` — the first sweep that found the story's runner with no live
  socket while the story waited at `ci`. Cleared by the next sweep that finds it live. Past
  `MergeExecution.runner_gone_after_seconds/0` the story is escalated over the control-only
  edge `:runner_gone` rather than re-queued. A map rather than a timestamp column because it is
  head-keyed too, and a head-keyed value is copied into the `retracted` part of a chained
  entry's payload, which carries JSON values only.

  ## `story_stage_events_event` gains `merge_instructed` and `runner_absence`

  Every write to the row leaves an event. No backfill and no manual step: both columns start
  NULL, which reads as "no instruction sent" and "runner not known absent".

  ## Rollback

  Refused while any row carries either new event name: those rows are the only record of
  when a merge was instructed and when a runner went missing, and the old allow-list cannot
  come back while they exist. Delete them by hand first if that history is to go.
  """

  use Ecto.Migration

  def up do
    alter table(:story_stages) do
      add :merge_instruction, :map, null: true
      add :runner_absence, :map, null: true
    end

    create constraint(:story_stages, :story_stages_merge_instruction_object,
             check: "jsonb_typeof(merge_instruction) = 'object'"
           )

    create constraint(:story_stages, :story_stages_runner_absence_object,
             check: "jsonb_typeof(runner_absence) = 'object'"
           )

    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check:
               "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound', " <>
                 "'merge_gate_unevaluated', 'post_deploy_unresolved', " <>
                 "'merge_instructed', 'runner_absence')"
           )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM story_stage_events
        WHERE event IN ('merge_instructed', 'runner_absence')
      ) THEN
        RAISE EXCEPTION 'refusing to roll back: story_stage_events holds merge_instructed or runner_absence rows, the only record of when a merge was instructed and a runner went missing; delete them by hand first';
      END IF;
    END
    $$;
    """)

    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check:
               "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound', " <>
                 "'merge_gate_unevaluated', 'post_deploy_unresolved')"
           )

    drop constraint(:story_stages, :story_stages_runner_absence_object)
    drop constraint(:story_stages, :story_stages_merge_instruction_object)

    alter table(:story_stages) do
      remove :runner_absence
      remove :merge_instruction
    end
  end
end
