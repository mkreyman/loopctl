defmodule Loopctl.Repo.Migrations.CreateStoryStages do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Issue #803: the per-story delivery stage machine (design §3).
  #
  # `story_stages` is ONE row per story and the only authoritative record of where a story is
  # in the delivery loop. Nothing caches it: a runner, a DurableServer or a second loopctl
  # node reads this row and advances it with a compare-and-set, so the answer after any crash
  # or partition is whatever committed here.
  #
  # The side-effect identity columns are written by the stage that produces each effect
  # BEFORE it acts, so a replayed stage finds its effect instead of making a second worktree,
  # PR or deploy. `claim_epoch` is the claim the row was last written under; a row behind
  # `stories.claim_epoch` is stale and refused (`Loopctl.Delivery.Stages`).
  #
  # `story_stage_events` is the non-chained history. Custody-critical transitions (claim,
  # merge, escalate) also go on the audit chain; the rest do not, because the chain
  # serialises every writer in a tenant on its head row (design §11).
  #
  # The stage list in the CHECK mirrors `Loopctl.Delivery.StageMachine.stages/0`; a test
  # reads this constraint back from pg_constraint and fails when the two disagree.
  @stages ~w(detected triaged queued claimed worktree implementing reviewing pr_open ci
             merged deployed verified done escalated failed)

  @sha "'^[0-9a-f]{40}([0-9a-f]{24})?$'"

  def up do
    stage_list = Enum.map_join(@stages, ", ", &"'#{&1}'")

    create table(:story_stages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :stage, :text, null: false
      add :claim_epoch, :bigint, null: false

      # A deleted runner (rotation is delete + re-enrol) must not take the stage row with it.
      add :runner_id, references(:runners, type: :binary_id, on_delete: :nilify_all), null: true

      add :worktree_path, :text, null: true
      add :branch, :text, null: true
      add :pr_number, :bigint, null: true
      add :head_sha, :text, null: true
      add :merge_sha, :text, null: true
      add :release_id, :text, null: true

      add :attempts, :map, null: false, default: %{}
      add :escalation_reason, :text, null: true
      add :lock_version, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:story_stages, [:tenant_id, :story_id],
             name: :story_stages_tenant_story_uidx
           )

    create index(:story_stages, [:tenant_id, :stage])

    create constraint(:story_stages, :story_stages_stage, check: "stage IN (#{stage_list})")
    create constraint(:story_stages, :story_stages_claim_epoch, check: "claim_epoch >= 0")
    create constraint(:story_stages, :story_stages_lock_version, check: "lock_version >= 0")
    create constraint(:story_stages, :story_stages_pr_number, check: "pr_number > 0")

    create constraint(:story_stages, :story_stages_head_sha, check: "head_sha ~ #{@sha}")
    create constraint(:story_stages, :story_stages_merge_sha, check: "merge_sha ~ #{@sha}")

    create constraint(:story_stages, :story_stages_text_bounds,
             check:
               "char_length(worktree_path) BETWEEN 1 AND 4096 " <>
                 "AND char_length(branch) BETWEEN 1 AND 255 " <>
                 "AND char_length(release_id) BETWEEN 1 AND 255 " <>
                 "AND char_length(escalation_reason) BETWEEN 1 AND 4000"
           )

    create constraint(:story_stages, :story_stages_attempts_object,
             check: "jsonb_typeof(attempts) = 'object'"
           )

    # An escalated story always says why.
    create constraint(:story_stages, :story_stages_escalation_reason,
             check: "stage <> 'escalated' OR escalation_reason IS NOT NULL"
           )

    enable_rls(:story_stages)

    create table(:story_stage_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :story_stage_id,
          references(:story_stages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :story_id, :binary_id, null: false
      add :event, :text, null: false
      add :from_stage, :text, null: true
      add :to_stage, :text, null: false
      add :edge, :text, null: true
      add :claim_epoch, :bigint, null: false
      add :lock_version, :bigint, null: false
      add :actor_label, :text, null: true
      add :data, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:story_stage_events, [:tenant_id, :story_id, :inserted_at])
    create index(:story_stage_events, [:story_stage_id])

    create constraint(:story_stage_events, :story_stage_events_event,
             check: "event IN ('opened', 'transitioned', 'effect_recorded', 'rebound')"
           )

    enable_rls(:story_stage_events)
  end

  def down do
    drop table(:story_stage_events)
    drop table(:story_stages)
  end
end
