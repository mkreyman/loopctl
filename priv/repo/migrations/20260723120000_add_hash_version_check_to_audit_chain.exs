defmodule Loopctl.Repo.Migrations.AddHashVersionCheckToAuditChain do
  use Ecto.Migration

  @moduledoc """
  Constrains `audit_chain.hash_version` to the leaf-hash versions this codebase
  can actually construct (LCP-1 §8.4 defines 1 and 2).

  `Loopctl.AuditChain.LeafHash.compute/2` only knows versions 1 and 2; an entry
  carrying any other value cannot be recomputed and so cannot be validated. This
  CHECK makes an out-of-range version unwritable at the database level, keeping
  the tamper-detection path from ever meeting a version it must reject. Purely
  additive: every existing row is 1 (the migration default) or 2 (new writes),
  both of which satisfy the constraint, so it validates without a rewrite.
  """

  def change do
    create constraint(:audit_chain, :audit_chain_hash_version_valid,
             check: "hash_version IN (1, 2)"
           )
  end
end
