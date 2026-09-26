defmodule Loopctl.Delivery.Claimant do
  @moduledoc """
  The ONE definition of "this caller is the story's current claimant under this epoch", shared
  by every path that fences on it (`Loopctl.Delivery.Escalations`, `Loopctl.Threads`).

  An UNCLAIMED story is not this caller's, and a key with no agent must never satisfy the
  check by matching that nil: an unclaimed story is refused before any comparison, so a nil
  agent can only ever be compared against a real one, and never equals it.

  `live?/2` is the liveness half, and it is `Loopctl.Progress.live_claim?/2` (a claimed status
  and a lease not yet passed) plus the review marker: once review is requested the
  implementer's lease has stopped applying, exactly as the reclaimer reads it. A reported,
  released or verified story is not live, so its implementer can no longer add to it.
  """

  @doc """
  `:ok` when `agent_id` is the story's assigned agent and `epoch` its current `claim_epoch`.
  `story` is anything carrying `assigned_agent_id` and `claim_epoch`.
  """
  @spec check(map(), Ecto.UUID.t() | nil, term()) ::
          :ok | {:error, :not_claimant | :stale_claim_epoch}
  def check(%{assigned_agent_id: assigned, claim_epoch: current}, agent_id, epoch) do
    cond do
      is_nil(assigned) -> {:error, :not_claimant}
      assigned != agent_id -> {:error, :not_claimant}
      current != epoch -> {:error, :stale_claim_epoch}
      true -> :ok
    end
  end

  @doc """
  True while the claim still accepts the implementer's work: live by
  `Loopctl.Progress.live_claim?/2` and no review requested. `story` must carry
  `agent_status`, `claimed_until` and `review_requested_at`.
  """
  @spec live?(Loopctl.WorkBreakdown.Story.t(), DateTime.t()) :: boolean()
  def live?(story, now),
    do: is_nil(story.review_requested_at) and Loopctl.Progress.live_claim?(story, now)
end
