defmodule Loopctl.AuditChain.Entry do
  @moduledoc """
  Schema for the `audit_chain` table — tamper-evident, hash-chained,
  append-only audit log entries.

  Each entry references the previous entry's hash, creating an
  immutable chain per tenant. DB triggers enforce:
  - No updates (immutable)
  - No deletes (append-only)
  - Sequential chain_position (no gaps)
  - Correct prev_entry_hash linkage
  """

  use Loopctl.Schema

  alias Loopctl.AuditChain.LeafHash

  @type t :: %__MODULE__{}

  schema "audit_chain" do
    field :tenant_id, Ecto.UUID
    field :chain_position, :integer
    field :prev_entry_hash, :binary
    field :action, :string
    field :actor_lineage, {:array, :string}, default: []
    field :entity_type, :string
    field :entity_id, Ecto.UUID
    field :payload, :map, default: %{}
    field :entry_hash, :binary
    # Single-sourced from the writer so the default version can never silently
    # diverge from the algorithm `LeafHash.compute/2` actually uses. If this
    # defaulted to a stale version (e.g. 1) while `current_version/0` advanced to
    # 2, any insert path that computed a v2 hash but omitted an explicit
    # `hash_version` would store the wrong version, and `entry_hash_valid?/1`
    # would then recompute with the wrong construction and report a FALSE
    # tampering positive.
    field :hash_version, :integer, default: LeafHash.current_version()
    field :inserted_at, :utc_datetime_usec
  end

  @doc false
  def changeset(entry \\ %__MODULE__{}, attrs) do
    entry
    |> cast(attrs, [
      :chain_position,
      :prev_entry_hash,
      :action,
      :actor_lineage,
      :entity_type,
      :entity_id,
      :payload,
      :entry_hash,
      :hash_version,
      :inserted_at
    ])
    |> validate_required([
      :chain_position,
      :prev_entry_hash,
      :action,
      :actor_lineage,
      :entity_type,
      :payload,
      :entry_hash,
      :hash_version
    ])
  end
end
