defmodule Loopctl.Repo.Migrations.NormalizeTenantIsolationPoliciesToWrapper do
  @moduledoc """
  sec-5 (#460): normalize the 8 RLS policies that used the raw
  current_setting('app.current_tenant_id', true)::uuid cast to the
  exception-safe current_tenant_id() wrapper, AND unify their name to the
  canonical `tenant_isolation` that RlsHelpers.enable_rls/1 emits. After this
  migration a single policy-name and a single predicate convention cover every
  tenant-scoped table (#460's second motivation: "two patterns for the same
  invariant invites future mistakes").

  Consistency / defense-in-depth; no live isolation impact — both variants deny
  ALL rows whenever no valid tenant is in scope, so nothing leaks either way.
  The only behavioral difference is on a MALFORMED `SET` value: the raw cast
  RAISES (an empty string '' or a non-UUID set into the GUC aborts the query
  with a 500-class error), while the wrapper's `EXCEPTION WHEN OTHERS` handler
  degrades that raise to a clean NULL — a zero-row denial. Note that when the
  GUC is simply UNSET, `current_setting(name, true)` already returns NULL (via
  missing_ok=true) and NULL::uuid is NULL, so BOTH variants deny cleanly with no
  raise — the wrapper only changes behavior for the malformed-SET case. It is
  preferred because it fails soft, and because every other policy in the schema
  already uses it via RlsHelpers.enable_rls/1.

  Two in-place ALTERs per table, both fully reversible: first RENAME
  `tenant_isolation_policy` -> `tenant_isolation`, then rewrite the USING
  predicate to the wrapper. Neither statement DROPs the policy, so there is no
  window where the table is unprotected. RLS stays ENABLE (never FORCE); GRANTs
  are handled globally by ALTER DEFAULT PRIVILEGES.
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
      # 1. Unify the policy NAME with the canonical `tenant_isolation`.
      execute(
        "ALTER POLICY tenant_isolation_policy ON #{table} RENAME TO tenant_isolation",
        "ALTER POLICY tenant_isolation ON #{table} RENAME TO tenant_isolation_policy"
      )

      # 2. Normalize the USING predicate to the exception-safe wrapper.
      execute(
        "ALTER POLICY tenant_isolation ON #{table} USING (tenant_id = current_tenant_id())",
        "ALTER POLICY tenant_isolation ON #{table} USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)"
      )
    end
  end
end
