defmodule Loopctl.Repo.Migrations.NormalizeTenantIsolationPoliciesToWrapper do
  @moduledoc """
  sec-5 (#460): normalize the 8 tenant_isolation_policy definitions that used the
  raw current_setting('app.current_tenant_id', true)::uuid cast to the
  exception-safe current_tenant_id() wrapper, matching every other RLS policy.

  Consistency / defense-in-depth; no live isolation impact. When the GUC is
  unset the raw cast RAISES and aborts the query, while the wrapper returns NULL
  (a clean denial of all rows) — nothing leaks either way. The wrapper is
  preferred because it fails soft (clean denial) instead of a 500-class error,
  and because every other policy in the schema already uses it via
  RlsHelpers.enable_rls/1.

  The policy name is preserved: each table keeps the existing name
  `tenant_isolation_policy` (NOT the bare `tenant_isolation` the macro emits). We
  ALTER the same-named policy's USING predicate in place — a single statement, no
  window where the policy is absent, and fully reversible. RLS stays ENABLE
  (never FORCE); GRANTs are handled globally by ALTER DEFAULT PRIVILEGES.
  """
  use Ecto.Migration

  # Fixed compile-time allowlist (not user input) — interpolation is safe.
  @tables ~w(
    audit_signed_tree_heads
    audit_sth_checkpoints
    tenant_audit_key_history
    capability_tokens
    audit_chain
    dispatches
    verification_runs
    story_acceptance_criteria
  )

  def change do
    for table <- @tables do
      execute(
        "ALTER POLICY tenant_isolation_policy ON #{table} USING (tenant_id = current_tenant_id())",
        "ALTER POLICY tenant_isolation_policy ON #{table} USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)"
      )
    end
  end
end
