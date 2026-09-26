defmodule LoopctlWeb.ActorLabel do
  @moduledoc """
  The ONE attribution string for a calling API key: its agent when it has one, otherwise the
  key itself. The stage machine records it as `actor_label` and the change thread as
  `author_principal`, so the two must never be spelled differently.
  """

  @doc "`agent:<id>` for a key with an agent, `api_key:<id>` for one without."
  @spec of(map()) :: String.t()
  def of(%{agent_id: nil, id: key_id}), do: "api_key:" <> key_id
  def of(%{agent_id: agent_id}), do: agent(agent_id)

  @doc """
  The label for an agent acting without an API key of its own in hand — a runner's sessions,
  which act as the runner's agent (`Loopctl.Delivery.RunnerThreads`). The same string `of/1`
  gives a key with that agent, so a write made over HTTP and its resend over the socket are
  one author.
  """
  @spec agent(Ecto.UUID.t()) :: String.t()
  def agent(agent_id), do: "agent:" <> agent_id
end
