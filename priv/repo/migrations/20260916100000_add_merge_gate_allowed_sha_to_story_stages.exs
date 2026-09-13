defmodule Loopctl.Repo.Migrations.AddMergeGateAllowedShaToStoryStages do
  use Ecto.Migration

  # Issue #803 review round 1, H1: the merge precondition's ALLOW has to be a recorded fact,
  # not a value that vanishes when the caller returns.
  #
  # Without it, a pull request the forge reports as already merged was indistinguishable
  # from one the gate never authorised — a merge performed around the gate, or after it
  # refused, came back "already merged, no reasons" and the last gate before an outward
  # effect ratified it. The column is the answer to "did THIS head get an allow?": the gate
  # writes the head sha it judged when it allows, and an already-merged pull request whose
  # head does not match a recorded allow is escalated as an ungated merge rather than
  # reported clean.
  #
  # It is a side-effect identity like the others (`Loopctl.Delivery.StageMachine`'s
  # `@effect_stages`), written only at `ci` through `Loopctl.Delivery.Stages.record_effect/5`
  # — the one writer of this table — and cleared by every edge that clears `head_sha`,
  # because an allow means nothing once the head it was granted for is gone.
  @sha "'^[0-9a-f]{40}([0-9a-f]{24})?$'"

  def up do
    alter table(:story_stages) do
      add :merge_gate_allowed_sha, :text, null: true
    end

    create constraint(:story_stages, :story_stages_merge_gate_allowed_sha,
             check: "merge_gate_allowed_sha ~ #{@sha}"
           )
  end

  def down do
    drop constraint(:story_stages, :story_stages_merge_gate_allowed_sha)

    alter table(:story_stages) do
      remove :merge_gate_allowed_sha
    end
  end
end
