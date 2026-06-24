defmodule LoopctlWeb.Helpers.Visibility do
  @moduledoc """
  Computes the agent-memory visibility scope for a read request (#163).

  Agent-memory articles carry `metadata.visibility ∈ {shared, private, owner}`.
  `private`/`owner` memories must only be retrievable by the owning agent. This
  helper turns the authenticated API key into a `:visibility_agent_id` read option
  that the `Loopctl.Knowledge` read paths apply:

  - **agent** role → `[visibility_agent_id: <key.agent_id>]`. The key's verified
    `agent_id` (stringified) is the identity; an agent sees `shared` articles plus
    its own memories. An agent key with no `agent_id` owns nothing, so the empty
    string scopes it to `shared` only.
  - **higher roles** (orchestrator/user/superadmin) → `[]`. Trusted/observability
    roles see everything; no visibility filter is applied.

  This is the read half of the trust model; the write half (binding
  `metadata.agent_id` to the key on create) lives in `ArticleController`.
  """

  @doc """
  Returns the visibility read option for the request's API key, to be merged into
  the opts passed to `Loopctl.Knowledge` read functions.
  """
  @spec scope_opts(Plug.Conn.t()) :: keyword()
  def scope_opts(%Plug.Conn{assigns: %{current_api_key: %{role: :agent} = key}}) do
    [visibility_agent_id: to_string(key.agent_id)]
  end

  # Higher roles (or any request without an agent-role key) see everything.
  def scope_opts(%Plug.Conn{}), do: []
end
