defmodule Loopctl.Repo.Migrations.EnableRlsOnAuditPendingViolations do
  @moduledoc """
  rls-01 (GHSA-q46q-6f5q-f7xj): the `audit_pending_violations` table was created
  with a `tenant_id` column but WITHOUT Row Level Security — it had
  `relrowsecurity = false` and zero policies, while every sibling tenant table is
  RLS-enforced. Under the RLS-enforced `loopctl_app` role (which is GRANTed ALL by
  fly-db-setup), the app could read/write ALL tenants' rows unfiltered. Today only
  superadmin/AdminRepo touches this table so there is no live leak, but the
  mandatory tenant-isolation invariant was broken. This closes it (defense in
  depth, L2 database invariant per docs/chain-of-custody-v2.md §2.1/§2.4).

  Uses the shared `RlsHelpers.enable_rls/1` so this table matches every other
  tenant table: `ENABLE ROW LEVEL SECURITY` (not FORCE — the production owner
  role has no BYPASSRLS) + a `tenant_isolation` policy
  `USING (tenant_id = current_tenant_id())`. Reversible: `down` disables RLS and
  drops the policy.
  """
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  def change do
    enable_rls(:audit_pending_violations)
  end
end
