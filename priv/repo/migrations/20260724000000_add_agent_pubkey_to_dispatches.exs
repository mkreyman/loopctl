defmodule Loopctl.Repo.Migrations.AddAgentPubkeyToDispatches do
  use Ecto.Migration

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
  A CHECK binds `alg` to the algorithms this codebase verifies, and ties the two
  columns together so a half-enrolled dispatch (one column set, the other null)
  cannot exist.
  """

  def up do
    alter table(:dispatches) do
      add :agent_pubkey, :binary
      add :alg, :string
    end

    # Both-or-neither, and alg restricted to what LCP-1 §6.1 defines. NOT VALID is
    # unnecessary here: the table is small and every existing row has both NULL,
    # which satisfies the constraint, so validation is trivial.
    execute("""
    ALTER TABLE dispatches
      ADD CONSTRAINT dispatches_signed_profile_valid
      CHECK (
        (agent_pubkey IS NULL AND alg IS NULL)
        OR (agent_pubkey IS NOT NULL AND alg IN ('ed25519'))
      )
    """)
  end

  def down do
    execute("ALTER TABLE dispatches DROP CONSTRAINT IF EXISTS dispatches_signed_profile_valid")

    alter table(:dispatches) do
      remove :agent_pubkey
      remove :alg
    end
  end
end
