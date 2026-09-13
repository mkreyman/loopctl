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

  # The rollback DESTROYS HISTORY, and it is gated on an operator saying so.
  #
  # The old event-name allow-list cannot come back while rows carry the new name, so the
  # rollback has to delete them. But `story_stage_events` is the complete, append-only
  # record of a story's stage row: the COLUMN this migration adds is rebuilt by the next
  # sweep, and the EVENTS are not — rolling back and reapplying loses when each story
  # stopped being verifiable, which is exactly what an operator investigating a stuck
  # delivery would go looking for.
  #
  # So the deletion is opt-in. `POST_DEPLOY_ROLLBACK_DELETES_EVENTS=1` performs it; anything
  # else refuses with a message naming what would go.
  @opt_in "POST_DEPLOY_ROLLBACK_DELETES_EVENTS"

  def down do
    unless System.get_env(@opt_in) == "1" do
      raise """
      Refusing to roll back: this would DELETE every `post_deploy_unresolved` row from       story_stage_events, which is the append-only record of when each story stopped being       verifiable. The column it also drops is rebuilt by the next sweep; those events are       not, and reapplying the migration does not bring them back.

      Re-run with #{@opt_in}=1 to delete them and roll back.
      """
    end

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
