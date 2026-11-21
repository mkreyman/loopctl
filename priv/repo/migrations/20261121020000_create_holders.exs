defmodule Loopctl.Repo.Migrations.CreateHolders do
  @moduledoc """
  US-52.13 (Epic 52 release 3): one `holders` row per session, and a credential per holder.

  Every fleet session authenticates with one shared agent key, so loopctl cannot tell two
  sessions of one agent apart (loopctl#707). A holder is that session: its kind, the host and
  worktree it runs in, and a lease it keeps alive by heartbeating. The agent stays the account
  that owns keys; holders hang off it.

  ## The two api_keys indexes

  `api_keys_one_role_per_agent_idx` (20260411233503) allows one live key per agent and role,
  which is exactly what stops a second session of one agent from holding a credential at all.
  It is rebuilt with `holder_id IS NULL` added to its predicate, so it keeps meaning what it
  meant for every key that is not a holder's, and `api_keys_one_live_key_per_holder_idx` holds
  a holder to one live credential instead. Neither predicate can test expiry (a partial index
  predicate must be IMMUTABLE and `now()` is not), which is why ending a holder always REVOKES
  its credential rather than letting it expire.

  The rebuild is a DROP and CREATE in one transaction, so no write ever sees the table without
  the uniqueness rule; `api_keys` is small, and a plain CREATE INDEX blocks writes to it only,
  never the reads every request makes.

  ## Isolation

  `tenant_id` on every row, RLS ENABLED (not FORCE: the production role owns the table without
  BYPASSRLS). `holders_live_session_uidx` keeps one live holder per (tenant, agent, session),
  which is what makes a retried register return the same holder rather than a second one.

  No backfill and no manual step: the table starts empty, and every existing key has a NULL
  `holder_id`, so the rebuilt index admits exactly the rows the old one did.
  """

  use Ecto.Migration

  def up do
    create table(:holders, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # The account the holder acts for. No FK: api_keys.agent_id carries none either
      # (20260411233503 dropped it), and a holder must outlive an agent row's churn as the
      # record of who held what.
      add :agent_id, :binary_id, null: false
      add :kind, :string, null: false
      add :session_id, :text, null: false
      add :host, :text, null: false
      add :worktree, :text
      add :dispatch_id, :binary_id
      add :last_seen_at, :utc_datetime_usec, null: false
      add :lease_until, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:holders, :holders_kind_known,
             check: "kind IN ('runner_session', 'interactive', 'cloud')"
           )

    create constraint(:holders, :holders_ended_reason_known,
             check: "ended_reason IS NULL OR ended_reason IN ('ended', 'lapsed')"
           )

    # An ended holder says why; a live one says nothing.
    create constraint(:holders, :holders_ended_shape,
             check: "(ended_at IS NULL) = (ended_reason IS NULL)"
           )

    create unique_index(:holders, [:tenant_id, :agent_id, :session_id],
             where: "ended_at IS NULL",
             name: :holders_live_session_uidx
           )

    create index(:holders, [:tenant_id, :agent_id])

    execute("ALTER TABLE holders ENABLE ROW LEVEL SECURITY")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'holders' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON holders USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """)

    # NO ACTION, not RESTRICT: a tenant delete cascades to BOTH tables in one statement, and
    # RESTRICT is checked the moment a holder row goes, before its keys may have; NO ACTION is
    # checked at the end of the statement. A holder is never deleted on its own (it is ENDED).
    alter table(:api_keys) do
      add :holder_id, references(:holders, type: :binary_id, on_delete: :nothing)
    end

    drop index(:api_keys, [:tenant_id, :agent_id, :role], name: :api_keys_one_role_per_agent_idx)

    create unique_index(:api_keys, [:tenant_id, :agent_id, :role],
             where:
               "revoked_at IS NULL AND role NOT IN ('user', 'superadmin') AND holder_id IS NULL",
             name: :api_keys_one_role_per_agent_idx
           )

    create unique_index(:api_keys, [:holder_id],
             where: "revoked_at IS NULL AND holder_id IS NOT NULL",
             name: :api_keys_one_live_key_per_holder_idx
           )
  end

  def down do
    drop index(:api_keys, [:holder_id], name: :api_keys_one_live_key_per_holder_idx)
    drop index(:api_keys, [:tenant_id, :agent_id, :role], name: :api_keys_one_role_per_agent_idx)

    create unique_index(:api_keys, [:tenant_id, :agent_id, :role],
             where: "revoked_at IS NULL AND role NOT IN ('user', 'superadmin')",
             name: :api_keys_one_role_per_agent_idx
           )

    alter table(:api_keys) do
      remove :holder_id
    end

    execute("DROP POLICY IF EXISTS tenant_isolation ON holders")
    drop table(:holders)
  end
end
