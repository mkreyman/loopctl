defmodule Loopctl.Repo.Migrations.AddAgentPubkeyToDispatches do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Adds the LCP-1 §9 `signed`-profile columns to `dispatches`: the agent's own
  public key and the signature algorithm it signs with.

  PURELY ADDITIVE and non-breaking:

    * Both columns are NULLABLE. A `bearer`-profile dispatch (every dispatch today)
      carries NULL for both, and nothing about its behaviour changes — the signed
      path is only consulted when a dispatch was enrolled with a key.
    * No default, no backfill, no row rewrite.

  The agent holds the PRIVATE half; only the public half is ever recorded here
  (LCP-1 §9.1 — the protocol defines no path capable of carrying a private key).
  A CHECK binds `alg` to the algorithms this codebase verifies, asserts the Ed25519
  key length (32 octets), and ties the two columns together so a half-enrolled
  dispatch (one column set, the other null) cannot exist.

  The CHECK is added `NOT VALID` (a fast, metadata-only ADD CONSTRAINT that takes a
  brief lock and does NOT scan the table) and validated in a SEPARATE
  `VALIDATE CONSTRAINT` statement (SHARE UPDATE EXCLUSIVE, which does not block
  writes). `dispatches` is append-only (rows are soft-revoked via `revoked_at`,
  never deleted) and so grows unboundedly, so a single combined ADD+validate under
  ACCESS EXCLUSIVE would briefly block every write on the dispatch/custody path
  during the scan — the repo's established pattern for unbounded tables avoids that.
  """

  def up do
    alter table(:dispatches) do
      add :agent_pubkey, :binary
      add :alg, :string
    end

    # Metadata-only: records the constraint without scanning existing rows.
    execute("""
    ALTER TABLE dispatches
      ADD CONSTRAINT dispatches_signed_profile_valid
      CHECK (
        (agent_pubkey IS NULL AND alg IS NULL)
        OR (agent_pubkey IS NOT NULL AND alg = 'ed25519' AND octet_length(agent_pubkey) = 32)
      )
      NOT VALID
    """)

    # Validates under SHARE UPDATE EXCLUSIVE (does not block concurrent writes).
    execute("ALTER TABLE dispatches VALIDATE CONSTRAINT dispatches_signed_profile_valid")
  end

  def down do
    execute("ALTER TABLE dispatches DROP CONSTRAINT IF EXISTS dispatches_signed_profile_valid")

    alter table(:dispatches) do
      remove :agent_pubkey
      remove :alg
    end
  end
end
