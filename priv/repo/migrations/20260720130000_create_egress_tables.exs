defmodule Loopctl.Repo.Migrations.CreateEgressTables do
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  # US-41.4 (AC-41.4.11): every table introduced by the fail-closed egress guard
  # carries `tenant_id` and is protected by `enable_rls/1` (ENABLE, not FORCE —
  # see RlsHelpers). The DEPLOYMENT allowlist is deliberately NOT here: it is
  # operator-plane state (config/env), not tenant data, and lives outside RLS.

  def change do
    # --- local_only scope markings (AC-41.4.1 / AC-41.4.2) ---
    #
    # One row per marked scope. `project_id IS NULL` = the TENANT-scope marking;
    # a non-null `project_id` = that project's marking. Effective marking is the
    # MOST RESTRICTIVE of the two (resolved in Loopctl.Egress) — a project can
    # never relax a tenant marking, so there is no "off" override row semantics:
    # absence means "not marked".
    create table(:egress_scope_markings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: true

      add :local_only, :boolean, null: false, default: false
      add :enabled_by_actor_type, :string
      add :enabled_by_actor_id, :binary_id
      add :enabled_at, :utc_datetime_usec
      add :acknowledged_blocked_endpoints, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    # Two partial unique indexes: Postgres treats NULLs as distinct in a plain
    # unique index, so the tenant-scope row (project_id IS NULL) needs its own.
    create unique_index(:egress_scope_markings, [:tenant_id],
             where: "project_id IS NULL",
             name: :egress_scope_markings_tenant_scope_idx
           )

    create unique_index(:egress_scope_markings, [:tenant_id, :project_id],
             where: "project_id IS NOT NULL",
             name: :egress_scope_markings_project_scope_idx
           )

    enable_rls(:egress_scope_markings)

    # --- tenant-declared trusted endpoints (AC-41.4.5) ---
    #
    # An UNVERIFIED TENANT ATTESTATION: loopctl does not prove the declaring
    # tenant owns the host. Constraints enforced in the changeset + at pin time:
    #   (1) public addresses only (must pass UrlGuard's full denylist);
    #   (2) purpose-scoped (`inference` and/or `webhook`);
    #   (3) vendor hosts excluded.
    create table(:egress_trusted_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :host, :string, null: false
      add :purposes, {:array, :string}, null: false, default: []
      add :note, :string
      add :declared_by_actor_type, :string
      add :declared_by_actor_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:egress_trusted_endpoints, [:tenant_id, :host])

    create constraint(:egress_trusted_endpoints, :egress_trusted_endpoints_purposes_non_empty,
             check: "array_length(purposes, 1) >= 1"
           )

    enable_rls(:egress_trusted_endpoints)

    # --- aggregated blocked-decision records (AC-41.4.6) ---
    #
    # Blocking is cheap and happens BEFORE any network call, so one misconfigured
    # harvest loop would otherwise write thousands of rows a minute. Records are
    # DEDUPLICATED per (scope, endpoint, reason, window) with an occurrence count;
    # the exact per-call rate lives in the [:loopctl, :egress, :blocked] telemetry
    # counter, not here. US-41.7 turns these rows into the custody claim.
    create table(:egress_blocked_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: true

      add :scope_key, :string, null: false
      add :endpoint_host, :string, null: false
      add :reason, :string, null: false
      add :window_start, :utc_datetime_usec, null: false
      add :occurrence_count, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :egress_blocked_decisions,
             [:tenant_id, :scope_key, :endpoint_host, :reason, :window_start],
             name: :egress_blocked_decisions_window_idx
           )

    enable_rls(:egress_blocked_decisions)
  end
end
