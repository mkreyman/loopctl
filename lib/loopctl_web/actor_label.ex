defmodule LoopctlWeb.ActorLabel do
  @moduledoc """
  The ONE attribution string for a calling API key: its agent when it has one, otherwise the
  key itself. The stage machine records it as `actor_label` and the change thread as
  `author_principal`, so the two must never be spelled differently.
  """

  @doc "`agent:<id>` for a key with an agent, `api_key:<id>` for one without."
  @spec of(map()) :: String.t()
  def of(%{agent_id: nil, id: key_id}), do: "api_key:" <> key_id
  def of(%{agent_id: agent_id}), do: "agent:" <> agent_id
end
