defmodule Loopctl.Repo.Migrations.AddHashVersionToAuditChain do
  use Ecto.Migration

  @moduledoc """
  Adds `hash_version` to `audit_chain` so a verifier knows which leaf-hash
  construction produced each entry (LCP-1 §8.4).

  PURELY ADDITIVE and non-destructive by construction:

    * One column with a constant default. In PostgreSQL a NOT NULL column with a
      constant default is a catalog-only change — no table rewrite, no per-row
      update — so this does not touch the bytes of a single existing entry.
    * The default is 1, which is CORRECT for every pre-existing row: those
      entries genuinely were computed with the v1 construction. No backfill, no
      recompute, no rehash.
    * The BEFORE UPDATE / BEFORE DELETE immutability triggers remain in force, so
      even this migration cannot alter an existing entry's content — only the new
      column's default is stamped by the catalog.

  New entries written after this migration record the version they used (2);
  see `Loopctl.AuditChain.LeafHash`.
  """

  def change do
    alter table(:audit_chain) do
      add :hash_version, :smallint, null: false, default: 1
    end
  end
end
