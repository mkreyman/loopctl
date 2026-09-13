defmodule Loopctl.Repo.Migrations.CreateIntake do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Issues #803 and #804: GitHub webhook intake for the agent delivery loop.
  #
  # Three tables:
  #
  # * `intake_sources` binds ONE GitHub repository to ONE work project under a
  #   Cloak-encrypted webhook secret. The webhook URL carries the source id, so tenant
  #   resolution never trusts the payload's repository name; the payload must instead
  #   EQUAL the source's repository or be refused.
  # * `intake_records` is one row per (tenant, source, issue number): the queue entry
  #   triage consumes. Everything the reporter controls lives ONLY in `untrusted_*`
  #   columns, capped here as well as in code, so a caller that bypasses the context
  #   still cannot store an unbounded blob.
  # * `intake_deliveries` is one row per GitHub delivery. The unique index on
  #   (source_id, github_delivery_id) IS the idempotency key: a replay inserts nothing,
  #   decided by the index rather than by a read-then-insert that two concurrent posts
  #   would both pass. GitHub's "Redeliver" reuses the delivery id, so a redelivery is a
  #   replay too.
  def change do
    create table(:intake_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repo_full_name, :text, null: false
      add :webhook_secret, :binary, null: false
      add :revoked_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # GitHub repository names are case-insensitive, so the uniqueness is too.
    create unique_index(:intake_sources, ["tenant_id", "lower(repo_full_name)"],
             where: "revoked_at IS NULL",
             name: :intake_sources_active_repo_uidx
           )

    create constraint(:intake_sources, :intake_sources_repo_shape,
             check: "repo_full_name ~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'"
           )

    enable_rls(:intake_sources)

    create table(:intake_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_number, :integer, null: false
      add :github_issue_id, :bigint, null: true
      add :html_url, :text, null: true
      add :issue_state, :text, null: true
      add :issue_updated_at, :utc_datetime_usec, null: true

      add :untrusted_title, :text, null: false, default: ""
      add :untrusted_body, :text, null: false, default: ""
      add :untrusted_labels, {:array, :text}, null: false, default: []
      add :untrusted_author_login, :text, null: true
      add :untrusted_truncated, :boolean, null: false, default: false

      add :ticket_ref, :text, null: true
      add :ticket_id, :binary_id, null: true
      add :ticket_priority, :text, null: true
      add :ticket_kind, :text, null: true

      add :status, :text, null: false, default: "pending_triage"
      add :escalation_reasons, {:array, :text}, null: false, default: []
      add :escalated_at, :utc_datetime_usec, null: true
      add :last_action, :text, null: true
      add :last_delivery_id, :text, null: true

      # GitHub's issue.updated_at has one-second precision and a payload carries no other
      # ordering key, so two deliveries stamped with the same second cannot be ordered.
      add :order_ambiguous, :boolean, null: false, default: false
      add :order_ambiguous_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:intake_records, [:tenant_id, :source_id, :issue_number],
             name: :intake_records_issue_uidx
           )

    create index(:intake_records, [:tenant_id, :status])

    create constraint(:intake_records, :intake_records_status,
             check: "status IN ('pending_triage', 'escalated')"
           )

    # An escalated record always says when and why; a pending one never claims to.
    create constraint(:intake_records, :intake_records_escalation_shape,
             check:
               "(status = 'escalated') = (escalated_at IS NOT NULL) AND " <>
                 "(status <> 'escalated' OR cardinality(escalation_reasons) > 0)"
           )

    # An ambiguous order always names the second it is ambiguous at.
    create constraint(:intake_records, :intake_records_order_ambiguity_shape,
             check: "order_ambiguous = (order_ambiguous_at IS NOT NULL)"
           )

    # Mirrors the caps in Loopctl.Intake.GithubPayload.
    create constraint(:intake_records, :intake_records_untrusted_caps,
             check:
               "octet_length(untrusted_title) <= 1024 AND " <>
                 "octet_length(untrusted_body) <= 65536 AND " <>
                 "cardinality(untrusted_labels) <= 50 AND " <>
                 "(untrusted_author_login IS NULL OR octet_length(untrusted_author_login) <= 64)"
           )

    create constraint(:intake_records, :intake_records_ticket_shape,
             check:
               "(ticket_ref IS NULL OR ticket_ref ~ '^HCB-[0-9a-f]{8}$') AND " <>
                 "(ticket_priority IS NULL OR ticket_priority IN ('urgent', 'high', 'normal', 'low')) AND " <>
                 "(ticket_kind IS NULL OR ticket_kind IN ('bug', 'feature'))"
           )

    enable_rls(:intake_records)

    create table(:intake_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :github_delivery_id, :text, null: false
      add :event, :text, null: false
      add :action, :text, null: true
      add :outcome, :text, null: false
      add :issue_number, :integer, null: true
      add :payload_sha256, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:intake_deliveries, [:source_id, :github_delivery_id],
             name: :intake_deliveries_delivery_uidx
           )

    create index(:intake_deliveries, [:tenant_id, :inserted_at])

    create constraint(:intake_deliveries, :intake_deliveries_outcome,
             check: "outcome IN ('ping', 'recorded', 'ignored')"
           )

    enable_rls(:intake_deliveries)
  end
end
