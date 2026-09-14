defmodule Loopctl.Repo.Migrations.AddAgentIdToRunners do
  use Ecto.Migration

  @moduledoc """
  Issue #803: a runner names the AGENT its sessions work as.

  A dispatch claims the story it is sent for (`Loopctl.Delivery.Placement`), and a claim
  writes `stories.assigned_agent_id` — the identity every L4 custody gate runs its equality
  check against, alongside its lineage comparison. A runner had none, so a runner-claimed
  story named no agent at all.

  Leaving it NULL is not a cosmetic gap. The `stories_reported_done_requires_agent` CHECK is
  `agent_status <> 'reported_done' OR implementer_dispatch_id IS NULL OR assigned_agent_id IS
  NOT NULL`, and the same claim writes `implementer_dispatch_id` — so an agentless
  runner-claimed story could never reach `reported_done` at all. The column is therefore NOT
  NULL: "a runner always names an agent" is the invariant the placement path depends on, and
  a DB constraint is what makes it a fact rather than a hope.

  ## The agent is per MACHINE, not per runner row

  `runners_active_name_uidx` is partial on `revoked_at IS NULL`, so re-enrolling a revoked
  machine under the same name makes a SECOND runner row for the same machine. Both rows point
  at the one `runner:<name>` agent, which is right — it is the same machine doing the work —
  and it is why there is no unique index on `runners.agent_id`.

  The backfill is the same get-or-create: insert one `runner:<name>` agent per runner,
  `ON CONFLICT DO NOTHING` so an agent a tenant already named that way is reused rather than
  duplicated, then join by name. `Loopctl.Runners.enroll_runner/3` does exactly this for every
  runner enrolled after it.

  The `'runner:' || name` literal below is a SECOND copy of `Loopctl.Runners.agent_name/1`,
  because a migration cannot call application code. `runners_test.exs` asserts the ENROLL path
  against that function; nothing asserts this copy, so a change to the prefix has to be made in
  both places by hand — and a mismatch would strand the backfilled rows rather than break a
  test.

  The FK takes no `on_delete`: an agent a runner names must not be deletable out from under
  it, and nothing in the application deletes agents anyway.
  """

  def up do
    alter table(:runners) do
      add :agent_id, references(:agents, type: :binary_id), null: true
    end

    execute("""
    INSERT INTO agents (id, tenant_id, name, agent_type, status, last_seen_at, inserted_at, updated_at)
    SELECT gen_random_uuid(), r.tenant_id, 'runner:' || r.name, 'implementer', 'active',
           now(), now(), now()
      FROM runners r
    ON CONFLICT (tenant_id, name) DO NOTHING
    """)

    execute("""
    UPDATE runners r
       SET agent_id = a.id
      FROM agents a
     WHERE a.tenant_id = r.tenant_id
       AND a.name = 'runner:' || r.name
       AND r.agent_id IS NULL
    """)

    alter table(:runners) do
      modify :agent_id, :binary_id, null: false
    end

    create index(:runners, [:agent_id])
  end

  def down do
    drop index(:runners, [:agent_id])

    alter table(:runners) do
      remove :agent_id
    end
  end
end
