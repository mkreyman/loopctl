defmodule Loopctl.Delivery.Claimant do
  @moduledoc """
  The ONE definition of "this caller is the story's current claimant under this epoch", shared
  by every path that fences on it (`Loopctl.Delivery.Escalations`, `Loopctl.Threads`).

  An UNCLAIMED story is not this caller's, and a key with no agent must never satisfy the
  check by matching that nil: both halves of the comparison have to be a real agent, which is
  why this is not `assigned_agent_id == agent_id` alone. Claim LIVENESS (the lease) is not
  decided here; a caller that needs it asks `Loopctl.Progress.live_claim?/2` as well.
  """

  @doc """
  `:ok` when `agent_id` is the story's assigned agent and `epoch` its current `claim_epoch`.
  `story` is anything carrying `assigned_agent_id` and `claim_epoch`.
  """
  @spec check(map(), Ecto.UUID.t() | nil, term()) ::
          :ok | {:error, :not_claimant | :stale_claim_epoch}
  def check(%{assigned_agent_id: assigned, claim_epoch: current}, agent_id, epoch) do
    cond do
      is_nil(assigned) or is_nil(agent_id) -> {:error, :not_claimant}
      assigned != agent_id -> {:error, :not_claimant}
      current != epoch -> {:error, :stale_claim_epoch}
      true -> :ok
    end
  end
end
