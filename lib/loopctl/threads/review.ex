defmodule Loopctl.Threads.Review do
  @moduledoc """
  A review loopctl placed on a story's thread (`thread_reviews`, US-45.3): the runner dispatch
  of kind `review` that carries it, the runner and its agent, the claim epoch and checkpoint
  it reads, and the round it was placed for. Written only by `Loopctl.Threads.record_review/3`
  under the thread lock; nothing here is cast from a caller.

  A `finding` or `verdict` is accepted only over the runner socket, from the runner holding
  THIS row's dispatch as an accepted ledger row. No API key is minted for a review, so no key
  can be the judge (#901, #905).
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "thread_reviews" do
    tenant_field()

    field :story_id, :binary_id
    field :dispatch_id, :binary_id
    field :runner_id, :binary_id
    field :agent_id, :binary_id
    field :claim_epoch, :integer
    field :checkpoint_id, :binary_id
    field :round, :integer
    # The thread's last entry `seq` when this review was placed (see `Threads.Reviews`).
    field :placed_at_seq, :integer
    field :placed_by, :string

    timestamps(updated_at: false)
  end
end
