defmodule Loopctl.Repo.Migrations.CreateSpecTuningDrafts do
  @moduledoc """
  `spec_tuner@1` (Epic 48, US-48.13): the improvement loop's dispatch kind, the first
  dispatch with NO STORY, and the table its one effect answers.

  ## `runner_dispatches`: kind `spec_tune`, and `story_id` NULL for it alone

  The kind CHECK widens in the release that adds the spec, as for every kind before it
  (`Loopctl.Agents.RegistryTest` holds it equal to the registry). A tuning run is about a SPEC
  in a project, not about a story, so its ledger row carries no `story_id`, and the new CHECK
  `runner_dispatches_story_shape` makes that a property of the storage in BOTH directions: a
  `spec_tune` row has no story, every other row has one. Every row an older release wrote has
  a story and another kind, so the CHECK holds over existing rows and validates at once.

  ## `agent_run_outcomes.story_id` is NULL for the same rows

  The outcome row (US-48.12) is written from the ledger row's identity, so a tuning run's
  outcome row has no story either; the same shape CHECK holds it to `spec_tune`.

  ## `spec_tuning_drafts`

  One row per tuning run of one target spec in one project. NOTHING in loopctl applies a row:
  the template and the spec version change only through a pull request a person reviews and
  merges (AC-48.13.4), and an operator marks the draft `landed` with that PR's URL.

  - `status` — `pending` (dispatched, unanswered), `proposed` (loopctl's own judgement of the
    runner's scores: strictly better and no existing case regressed), `rejected` (it did not,
    `rejection_reasons` say why), `landed` (an operator recorded the PR), `superseded` (a
    later proposal for the same spec replaced it), `abandoned` (its dispatch ended unanswered).
  - `input` — the traces loopctl sent, FENCED untrusted text and loopctl's own values, as sent:
    each new eval case's input is the trace it names, so the case input is loopctl's and never
    the runner's.
  - `new_cases`, `diff`, `current_score`, `proposed_score`, `per_case` — the runner's answer,
    validated against `spec_tuner@1`'s result schema before it is stored. Session-authored DATA
    for a person to read; nothing here is executed.
  - `window_since` / `window_until` — the outcome rows the run learned from; the next run's
    window starts where this one's ended.

  ## Bounds on everything a session wrote

  The schema caps each field and the envelope caps the whole result
  (`RunnerAgentResultMessage.max_result_bytes/0`); the CHECKs here hold the same ceilings at the
  storage, so a path that skipped the cast still cannot store an unbounded value.

  ## The partial unique index is the concurrency

  `spec_tuning_drafts_pending_uidx` admits ONE `pending` row per (tenant, project, target
  spec): the dispatcher inserts it before it sends, so two passes racing on the same pair
  cannot both dispatch. `(tenant_id, dispatch_id)` makes the effect write once per dispatch.

  ## Isolation

  `tenant_id` on every row, RLS ENABLED (not FORCE: the production role owns the table without
  BYPASSRLS), with the same `tenant_isolation` policy as its siblings. No foreign key on
  `dispatch_id`: the ledger row is pruned and this record must outlive it.

  No backfill and no manual step: the table starts empty.
  """

  use Ecto.Migration

  def up do
    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement', 'reply_draft', 'verify', 'spec_tune')"
           )

    alter table(:runner_dispatches) do
      modify :story_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create constraint(:runner_dispatches, :runner_dispatches_story_shape,
             check: "(story_id IS NULL) = (kind = 'spec_tune')"
           )

    execute("ALTER TABLE agent_run_outcomes ALTER COLUMN story_id DROP NOT NULL")

    create constraint(:agent_run_outcomes, :agent_run_outcomes_story_shape,
             check: "(story_id IS NULL) = (kind = 'spec_tune')"
           )

    create table(:spec_tuning_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dispatch_id, :binary_id
      add :target_spec_id, :string, null: false
      add :target_spec_version, :integer, null: false
      add :template_id, :string, null: false
      add :from_version, :integer, null: false
      add :to_version, :integer
      add :eval_set, :string, null: false
      add :status, :string, null: false
      add :rejection_reasons, {:array, :string}, null: false, default: []
      add :window_since, :utc_datetime_usec
      add :window_until, :utc_datetime_usec, null: false
      add :outcome_rows, :integer, null: false
      add :input, :map, null: false
      add :new_cases, :map
      add :diff, :text
      add :current_score, :map
      add :proposed_score, :map
      add :per_case, :map
      add :pr_url, :string
      add :answered_at, :utc_datetime_usec
      add :landed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:spec_tuning_drafts, [:tenant_id, :dispatch_id],
             name: :spec_tuning_drafts_dispatch_uidx,
             where: "dispatch_id IS NOT NULL"
           )

    create unique_index(:spec_tuning_drafts, [:tenant_id, :project_id, :target_spec_id],
             name: :spec_tuning_drafts_pending_uidx,
             where: "status = 'pending'"
           )

    # The list endpoint, newest first, keyset on (inserted_at, id); and the window read.
    create index(:spec_tuning_drafts, [:tenant_id, :inserted_at, :id])
    create index(:spec_tuning_drafts, [:tenant_id, :project_id, :target_spec_id, :window_until])

    create constraint(:spec_tuning_drafts, :spec_tuning_drafts_status,
             check:
               "status IN ('pending', 'proposed', 'rejected', 'landed', 'superseded', 'abandoned')"
           )

    # An answered draft carries the runner's answer; a pending or abandoned one carries none.
    # A landed draft names the pull request that landed it, and nothing else does.
    create constraint(:spec_tuning_drafts, :spec_tuning_drafts_shape,
             check:
               "(status IN ('pending', 'abandoned') AND diff IS NULL AND answered_at IS NULL) OR " <>
                 "(status IN ('proposed', 'rejected', 'landed', 'superseded') " <>
                 "AND diff IS NOT NULL AND answered_at IS NOT NULL " <>
                 "AND new_cases IS NOT NULL AND current_score IS NOT NULL " <>
                 "AND proposed_score IS NOT NULL AND per_case IS NOT NULL)"
           )

    create constraint(:spec_tuning_drafts, :spec_tuning_drafts_landed,
             check:
               "(status = 'landed') = (pr_url IS NOT NULL AND landed_at IS NOT NULL) " <>
                 "AND (status <> 'rejected' OR cardinality(rejection_reasons) > 0)"
           )

    # The storage ceilings of everything a session or a trace put here (see the moduledoc).
    create constraint(:spec_tuning_drafts, :spec_tuning_drafts_bounds,
             check:
               "char_length(target_spec_id) <= 64 AND char_length(template_id) <= 64 " <>
                 "AND char_length(eval_set) <= 80 " <>
                 "AND target_spec_version > 0 AND from_version > 0 " <>
                 "AND (to_version IS NULL OR to_version > from_version) " <>
                 "AND outcome_rows >= 0 " <>
                 "AND (diff IS NULL OR char_length(diff) BETWEEN 1 AND 4000) " <>
                 "AND (pr_url IS NULL OR char_length(pr_url) BETWEEN 1 AND 500) " <>
                 "AND cardinality(rejection_reasons) <= 16 " <>
                 "AND octet_length(input::text) <= 64000 " <>
                 "AND (new_cases IS NULL OR octet_length(new_cases::text) <= 48000) " <>
                 "AND (per_case IS NULL OR octet_length(per_case::text) <= 48000) " <>
                 "AND (current_score IS NULL OR octet_length(current_score::text) <= 200) " <>
                 "AND (proposed_score IS NULL OR octet_length(proposed_score::text) <= 200)"
           )

    execute("ALTER TABLE spec_tuning_drafts ENABLE ROW LEVEL SECURITY")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'spec_tuning_drafts' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON spec_tuning_drafts USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON spec_tuning_drafts")
    drop table(:spec_tuning_drafts)

    drop constraint(:agent_run_outcomes, :agent_run_outcomes_story_shape)
    execute("DELETE FROM agent_run_outcomes WHERE story_id IS NULL")
    execute("ALTER TABLE agent_run_outcomes ALTER COLUMN story_id SET NOT NULL")

    drop constraint(:runner_dispatches, :runner_dispatches_story_shape)
    execute("DELETE FROM runner_dispatches WHERE kind = 'spec_tune'")

    alter table(:runner_dispatches) do
      modify :story_id, :binary_id, null: false, from: {:binary_id, null: true}
    end

    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement', 'reply_draft', 'verify')"
           )
  end
end
