defmodule Loopctl.Threads.Review do
  @moduledoc """
  A review dispatch loopctl placed on a story's thread (`thread_reviews`, US-45.3): the
  dispatch it minted for the reviewer, the checkpoint that review reads, and the round it was
  placed for. Written only by `Loopctl.Threads.Reviews.place/4`; nothing here is cast from a
  caller.

  A `finding` or `verdict` is accepted only from the key THIS row's dispatch minted, which is
  how loopctl knows the author is a reviewer it placed rather than inferring it from the
  calling key (#901).
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "thread_reviews" do
    tenant_field()

    field :story_id, :binary_id
    field :dispatch_id, :binary_id
    field :agent_id, :binary_id
    field :checkpoint_id, :binary_id
    field :round, :integer
    field :placed_by, :string

    timestamps(updated_at: false)
  end
end
