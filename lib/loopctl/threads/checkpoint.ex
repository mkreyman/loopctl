defmodule Loopctl.Threads.Checkpoint do
  @moduledoc """
  A commit on a story's thread branch that the story's current claimant reported
  (`thread_checkpoints`, US-45.1). Every field is set by `Loopctl.Threads`; nothing is cast
  from a caller except through `Loopctl.Threads.record_checkpoint/3`, which validates each.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "thread_checkpoints" do
    tenant_field()

    field :story_id, :binary_id
    field :seq, :integer
    field :kind, Ecto.Enum, values: [:checkpoint, :base_update], default: :checkpoint
    field :commit_sha, :string
    field :tree_sha, :string
    field :parent_checkpoint_id, :binary_id
    field :claim_epoch, :integer
    field :dispatch_id, :binary_id
    field :merge_commit_sha, :string
    # CI and gate evidence read for this exact SHA (US-45.6); empty until then.
    field :gate_evidence, :map, default: %{}

    timestamps()
  end
end
