defmodule Mix.Tasks.Loopctl.Audit.DiscoverViolators do
  @moduledoc """
  US-26.1.4 — Discovers pre-existing data violations that would break
  Chain of Custody v2 invariants.

  Runs read-only queries across all tenants and writes violations to
  the `audit_pending_violations` table.

  ## Usage

      mix loopctl.audit.discover_violators

  Exits with code 0 if no violations, 1 if any exist.
  """

  use Mix.Task

  @shortdoc "Discover pre-existing chain-of-custody violations"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    alias Loopctl.AdminRepo
    alias Loopctl.AuditChain.PendingViolation

    import Ecto.Query

    total = 0

    # (a) Cross-role agent binding: same (tenant_id, agent_id) with multiple active keys, different roles
    cross_role =
      AdminRepo.all(
        from(k in "api_keys",
          where: is_nil(k.revoked_at) and not is_nil(k.agent_id),
          group_by: [k.tenant_id, k.agent_id],
          having: count(fragment("DISTINCT ?", k.role)) > 1,
          select: %{
            tenant_id: k.tenant_id,
            agent_id: k.agent_id,
            roles: fragment("array_agg(DISTINCT ?)", k.role)
          }
        )
      )

    total = total + record_violations(cross_role, "cross_role_binding", "api_key")

    # (b) Nil-agent non-user key
    nil_agent =
      AdminRepo.all(
        from(k in "api_keys",
          where:
            is_nil(k.revoked_at) and k.role not in ["user", "superadmin"] and is_nil(k.agent_id),
          select: %{tenant_id: k.tenant_id, id: k.id, role: k.role}
        )
      )

    total = total + record_violations(nil_agent, "nil_agent_non_user_key", "api_key")

    # (c) api_key referencing a non-existent agent
    orphaned =
      AdminRepo.all(
        from(k in "api_keys",
          left_join: a in "agents",
          on: k.agent_id == a.id,
          where: not is_nil(k.agent_id) and is_nil(a.id),
          select: %{tenant_id: k.tenant_id, id: k.id, agent_id: k.agent_id}
        )
      )

    total = total + record_violations(orphaned, "orphaned_agent_ref", "api_key")

    if total == 0 do
      Mix.shell().info("No violations found. Merge is safe.")
    else
      Mix.shell().error("#{total} violation(s) found. Review at /admin/violators before merging.")
      Mix.raise("#{total} pre-existing violation(s)")
    end
  end

  defp record_violations(rows, violation_type, entity_type) do
    alias Loopctl.AdminRepo
    alias Loopctl.AuditChain.PendingViolation

    now = DateTime.utc_now()

    for row <- rows do
      %PendingViolation{}
      |> PendingViolation.changeset(%{
        tenant_id: Map.get(row, :tenant_id),
        violation_type: violation_type,
        entity_type: entity_type,
        entity_id: Map.get(row, :id) || Map.get(row, :agent_id),
        detail: Map.from_struct(row),
        discovered_at: now
      })
      |> AdminRepo.insert!(
        on_conflict: :nothing,
        conflict_target: [:id]
      )
    end

    count = length(rows)

    if count > 0 do
      Mix.shell().info("  #{violation_type}: #{count} violation(s)")
    end

    count
  end
end
