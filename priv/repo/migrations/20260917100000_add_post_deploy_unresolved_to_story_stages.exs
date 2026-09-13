defmodule Loopctl.Repo.Migrations.AddPostDeployUnresolvedToStoryStages do
  use Ecto.Migration

  # Issue #803 §9 / #805 item 2: the same backstop the merge gate already carries
  # (`merge_gate_unevaluated`), for the OTHER control-side gate.
  #
  # Post-deploy verification compares the sha actually running in the target deployment
  # against the story's recorded `merge_sha`. When the forge is transiently unavailable, or
  # the deploy has simply not settled yet, there is no verdict: the story STAYS at
  # `deployed` and the next sweep asks again. A fault that never clears would then produce
  # that same answer for ever, with no escalation written and nobody told — so consecutive
  # unresolved results are counted and the verifier escalates once the count passes its
  # bound.
  #
  # A SECOND column rather than reusing `merge_gate_unevaluated`, for two reasons. The two
  # counters are keyed to different identities — the merge gate's to `head_sha`, this one to
  # `merge_sha` — and clearing one must not clear the other, which sharing a column makes
  # impossible. And `merge_gate_unevaluated` is HEAD-keyed
  # (`Loopctl.Delivery.StageMachine.head_keyed/0`), so every edge that clears the head
  # clears it; this one is MERGE-keyed (`merge_keyed/0`) and is cleared with `merge_sha`
  # instead.
  #
  # Shape: `{"merge_sha": "<sha>", "count": <n>}`, NULL before the first one and after a
  # clear — the same "no count and cleared are one state" rule the merge gate's column has.
  def up do
    alter table(:story_stages) do
      add :post_deploy_unresolved, :map, null: true
    end

    create constraint(:story_stages, :story_stages_post_deploy_unresolved_object,
             check: "jsonb_typeof(post_deploy_unresolved) = 'object'"
           )

    # Every write to the row leaves an event, so an operator can see WHEN a story stopped
    # being verifiable and not merely that it did. The event-name CHECK is an allow-list.
    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check:
               "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound', " <>
                 "'merge_gate_unevaluated', 'post_deploy_unresolved')"
           )
  end

  def down do
    # The rows the UP migration made legal go before the old allow-list comes back, or the
    # rollback aborts on any database where the verifier has run once. The count they
    # record is rebuilt by the next sweep.
    execute "DELETE FROM story_stage_events WHERE event = 'post_deploy_unresolved'"

    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check:
               "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound', " <>
                 "'merge_gate_unevaluated')"
           )

    drop constraint(:story_stages, :story_stages_post_deploy_unresolved_object)

    alter table(:story_stages) do
      remove :post_deploy_unresolved
    end
  end
end
