defmodule Loopctl.AuditChain.SthCheckpoint do
  @moduledoc """
  US-35.1 — Per-tenant incremental STH checkpoint (a pure performance CACHE).

  Persists the stable Merkle sub-tree "peaks" that cover the first
  `chain_position + 1` audit entries of a tenant's chain, so a Signed Tree
  Head recompute can fold ONLY the entries appended above the checkpoint into
  those peaks instead of re-reading and re-hashing the entire chain (GH #350).

  ## Peaks representation

  `peaks` is a list of raw 32-byte SHA-256 hashes — the roots of the complete
  left-aligned power-of-2 blocks that make up the checkpointed prefix, ordered
  left-to-right by DESCENDING block height. A block of `2^k` leaves is fully
  paired internally by `Loopctl.AuditChain.merkle_tree/2` (Bitcoin-style
  padding only ever touches the rightmost element), so its subtree root is
  stable as leaves are appended to the right.

  The peaks' heights are NOT stored — they are exactly the set-bit positions of
  the leaf count (`chain_position + 1`), reconstructed at read time. A checkpoint
  whose `length(peaks)` disagrees with the popcount of `chain_position + 1` is
  structurally corrupt and MUST be ignored in favour of a full recompute
  (AC-35.1.5).

  Only raw hashes are stored — no entry contents / plaintext leak.

  This is a CACHE: any inconsistency degrades to a correct full recompute,
  never a wrong root.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "audit_sth_checkpoints" do
    field :tenant_id, Ecto.UUID
    field :chain_position, :integer
    field :peaks, {:array, :binary}
    timestamps()
  end

  @doc false
  def changeset(checkpoint \\ %__MODULE__{}, attrs) do
    checkpoint
    |> cast(attrs, [:chain_position, :peaks])
    |> validate_required([:chain_position, :peaks])
    |> validate_number(:chain_position, greater_than_or_equal_to: 0)
  end
end
