defmodule Loopctl.Delivery.Claimant do
  @moduledoc """
  The ONE definition of "this caller is the story's current claimant under this epoch", shared
  by every path that fences on it (`Loopctl.Delivery.Escalations`, `Loopctl.Threads`).

  An UNCLAIMED story is not this caller's, and a key with no agent must never satisfy the
  check by matching that nil: an unclaimed story is refused before any comparison, so a nil
  agent can only ever be compared against a real one, and never equals it.

  `lease_live?/2` is the lease half: a claim whose `claimed_until` has passed has ended even
  before the reclaimer runs. It reads the lease only, never `agent_status`, so a claimant
  that has reported its story done is still the claimant while its lease runs.
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

  @doc "True while the story's lease has not passed; a nil lease never expires."
  @spec lease_live?(map(), DateTime.t()) :: boolean()
  def lease_live?(%{claimed_until: nil}, _now), do: true
  def lease_live?(%{claimed_until: until}, now), do: DateTime.after?(until, now)
end
