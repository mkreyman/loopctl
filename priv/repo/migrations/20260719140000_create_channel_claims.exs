defmodule Loopctl.Repo.Migrations.CreateChannelClaims do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # US-40.B1: the exactly-once handoff-claim table for the Repo Coordination Bus
  # (Epic 40). Distinct from `channel_posts`: a post's slot uniqueness INCLUDES the
  # author (`agent_id`), so two agents racing the same handoff create two DISTINCT
  # slots and never conflict. Exactly-once REQUIRES uniqueness EXCLUDING the
  # claimant — `(tenant_id, project_id, ref)` — so the FIRST inserter wins and every
  # loser hits a UNIQUE violation mapped to a clean 409 already_claimed. That
  # invariant cannot be expressed on `channel_posts`; hence a dedicated table.
  def change do
    create table(:channel_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # The claimant is server-stamped from the verified key identity — a claim
      # always has an owner. FK to agents so ownership can never dangle (matches
      # channel_posts.agent_id / token_usage_reports).
      add :claimant_agent_id, references(:agents, type: :binary_id, on_delete: :delete_all),
        null: false

      # The claimed anchor, e.g. "handoff:repo#812". A free string (bounded in the
      # changeset), NOT a UUID — it names an out-of-band unit of work, not a row.
      add :ref, :text, null: false

      # Lifecycle timestamps. `claimed_at`/`lease_expires_at` are set server-side at
      # insert; `done_at` stays NULL until the claimant marks the handoff done.
      add :claimed_at, :utc_datetime_usec, null: false
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :done_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # THE exactly-once guarantee: a UNIQUE index on (tenant_id, project_id, ref)
    # EXCLUDING the claimant. Postgres serializes concurrent inserts on this index —
    # exactly one commits, the rest raise a unique violation the changeset's
    # `unique_constraint` maps to {:error, :already_claimed} -> 409. No SELECT-then-
    # INSERT, so no TOCTOU window (the reason INSERT-to-claim was chosen over a
    # row-lock/upsert claim).
    create unique_index(:channel_claims, [:tenant_id, :project_id, :ref],
             name: :channel_claims_ref_uidx
           )

    # Lifecycle-aware sweep support (US-40.B1 AC-40.B1.4). The sweeper reclaims only
    # (a) done claims past a retention window (done_at IS NOT NULL AND done_at < ...)
    # and (b) abandoned leases (done_at IS NULL AND lease_expires_at < now()). These
    # two partial indexes back exactly those predicates so the sweep seeks rather
    # than scans, and NEVER touches an open, unexpired claim.
    create index(:channel_claims, [:done_at],
             where: "done_at IS NOT NULL",
             name: :channel_claims_done_at_idx
           )

    create index(:channel_claims, [:lease_expires_at],
             where: "done_at IS NULL",
             name: :channel_claims_open_lease_idx
           )

    # Defense-in-depth: production isolation is AdminRepo + explicit tenant_id filter
    # (the coordination.ex convention); RLS is the second layer (ENABLE, not FORCE —
    # same as channel_posts and every other tenant table).
    enable_rls(:channel_claims)
  end
end
