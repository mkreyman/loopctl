defmodule Loopctl.Repo.RlsCoverageTest do
  @moduledoc """
  rls-01 regression (GHSA-q46q-6f5q-f7xj): a repo-wide invariant that EVERY
  tenant-scoped table has Row Level Security enabled AND at least one policy.

  This keys purely on the presence of a `tenant_id` column, so it catches both
  the `audit_pending_violations` gap this PR fixes AND any future tenant table
  that forgets `RlsHelpers.enable_rls/1`. Legitimately-global tables (no
  `tenant_id`, e.g. `tenants`, `schema_migrations`) are excluded automatically.

  Child partitions (`relispartition = true`) are excluded: RLS is enforced on the
  partitioned PARENT (`relkind = 'p'`, which IS checked here), and loopctl only
  ever queries through the parent — the partitions inherit that enforcement.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo

  @tenant_tables_sql """
  SELECT c.relname,
         c.relrowsecurity,
         (
           SELECT count(*)
           FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = c.relname
         ) AS policy_count
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p')
    AND c.relispartition = false
    AND EXISTS (
      SELECT 1
      FROM information_schema.columns col
      WHERE col.table_schema = 'public'
        AND col.table_name = c.relname
        AND col.column_name = 'tenant_id'
    )
  ORDER BY c.relname
  """

  test "every table with a tenant_id column has RLS enabled and >= 1 policy" do
    %{rows: rows} = AdminRepo.query!(@tenant_tables_sql, [])

    # Sanity: we actually discovered tenant-scoped tables (the query isn't a no-op)
    # and one of them is a table we know is tenant-scoped.
    refute rows == [], "expected to discover tenant-scoped tables via the catalog"
    table_names = Enum.map(rows, fn [name, _rls, _count] -> name end)
    assert "stories" in table_names
    assert "audit_pending_violations" in table_names

    offenders =
      for [name, rls, policy_count] <- rows,
          rls == false or policy_count == 0,
          do: %{table: name, rowsecurity: rls, policies: policy_count}

    assert offenders == [],
           "tenant-scoped tables missing RLS and/or a policy: #{inspect(offenders, pretty: true)}"
  end

  test "audit_pending_violations is RLS-enforced with a tenant_isolation policy (rls-01)" do
    %{rows: [[rowsecurity]]} =
      AdminRepo.query!(
        "SELECT relrowsecurity FROM pg_class WHERE relname = 'audit_pending_violations'",
        []
      )

    assert rowsecurity == true

    %{rows: [[qual]]} =
      AdminRepo.query!(
        "SELECT qual FROM pg_policies WHERE tablename = 'audit_pending_violations' AND policyname = 'tenant_isolation'",
        []
      )

    assert qual =~ "current_tenant_id()"
  end
end
