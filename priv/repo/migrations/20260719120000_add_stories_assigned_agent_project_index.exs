defmodule Loopctl.Repo.Migrations.AddStoriesAssignedAgentProjectIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # US-40.D3 review follow-up — coordination write-membership index.
  #
  # `Coordination.agent_member_of_project?/3` (coordination.ex) derives project
  # WRITE membership with `exists?` over
  # `stories WHERE tenant_id = $1 AND project_id = $2 AND assigned_agent_id = $3`.
  # The create migration (20260327161318_create_stories.exs:43) only added the
  # SINGLE-column `index(:stories, [:assigned_agent_id])`, so the 3-predicate
  # membership probe seeks on `assigned_agent_id` alone and then filter-rechecks
  # `project_id` in the heap. That is fine while an agent holds few assignments,
  # but a long-lived agent that accumulates many assignments across many projects
  # turns the per-post membership check into a heap scan over all its rows.
  #
  # Add the composite `(assigned_agent_id, project_id)` btree so the probe seeks
  # straight to the (agent, project) pair and the residual `tenant_id` predicate
  # rechecks only the one-or-few matching rows — keeping the check flat regardless
  # of assignment count. `assigned_agent_id` leads (highly selective) with
  # `project_id` second to match the membership predicate exactly.
  #
  # CREATE/DROP INDEX CONCURRENTLY (outside a DDL transaction, migration lock
  # disabled) so the build takes no ACCESS EXCLUSIVE / SHARE lock on `stories`.
  # Mirrors the repo's documented CONCURRENTLY convention
  # (20260718130000_drop_redundant_channel_posts_recent_idx.exs). `IF NOT
  # EXISTS`/`IF EXISTS` keep both directions idempotent-safe.
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS stories_assigned_agent_project_idx
    ON stories (assigned_agent_id, project_id)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS stories_assigned_agent_project_idx")
  end
end
