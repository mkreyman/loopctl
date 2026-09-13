defmodule Loopctl.Repo.Migrations.AddMergeGateUnevaluatedToStoryStages do
  use Ecto.Migration

  # Issue #803 review round 2, H1: the backstop under "no condition may retry forever with
  # nobody told".
  #
  # A merge-gate evaluation that hits a TRANSIENT forge fault answers `:unevaluated` and
  # transitions nothing, on purpose — one blip must not park a story on a human. But a fault
  # that never clears (a token that cannot read a repository's contents, a rate limit that
  # stays exhausted) then produces the same answer for ever: no escalation is written and
  # nobody is told. This counts consecutive unevaluated results per HEAD, and the gate
  # escalates once the count passes its bound.
  #
  # A dedicated column rather than `attempts`: that map's keys are EDGE names, defined by
  # `Loopctl.Delivery.StageMachine.counted?/1`, and a non-edge key in it would break what
  # "attempts" means. It is not a side-effect identity either — a counter is the one thing
  # `record_effect/5` cannot hold, since a second, DIFFERENT value is `:effect_conflict` by
  # design — so it gets its own writer, `Loopctl.Delivery.Stages.note_unevaluated/4`.
  #
  # Shape: `{"head_sha": "<sha>", "count": <n>}`, or `{}` before the first one. The head is
  # stored so the count RESETS when the head moves: a new head is new material, and a
  # story's history of blips at an older one should not escalate it.
  def up do
    alter table(:story_stages) do
      add :merge_gate_unevaluated, :map, null: false, default: %{}
    end

    create constraint(:story_stages, :story_stages_merge_gate_unevaluated_object,
             check: "jsonb_typeof(merge_gate_unevaluated) = 'object'"
           )

    # The count leaves an event, like every other write to the row, so an operator can see
    # WHEN a story went quiet and not merely that it did. The event-name CHECK is an
    # allow-list, so the new name goes in it.
    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check:
               "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound', " <>
                 "'merge_gate_unevaluated')"
           )
  end

  def down do
    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check: "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound')"
           )

    drop constraint(:story_stages, :story_stages_merge_gate_unevaluated_object)

    alter table(:story_stages) do
      remove :merge_gate_unevaluated
    end
  end
end
