defmodule Loopctl.Memory.Promoter.LLMRouter do
  @moduledoc """
  Tenant-aware router for `Loopctl.Memory.Promoter.LLMBehaviour` (US-41.3,
  AC-41.3.2).

  The module named by `config :loopctl, :promoter_llm, ...` stays the SINGLE
  resolution point; it is now this router, dispatching per call to the Anthropic
  or OpenAI-compatible sibling based on TENANT settings. `config/test.exs`'s Mox
  mapping is untouched.

  Session content is the most attacker-influenced payload in the system, so BOTH
  siblings share the same fixed system prompt and delimiter-neutralized user
  message (see `Loopctl.Memory.Promoter.OpenAiLLM`) — the routing decision never
  changes the hardening.

  Provider choice is tenant DATA, not deployment config — see
  `Loopctl.Knowledge.ContentExtractorRouter` for the full rationale.
  """

  @behaviour Loopctl.Memory.Promoter.LLMBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm
  alias Loopctl.Memory.Promoter.DefaultLLM
  alias Loopctl.Memory.Promoter.OpenAiLLM

  @doc "The sibling impl this tenant's calls dispatch to (TC-41.3.1)."
  @spec sibling_for(Ecto.UUID.t()) :: module()
  def sibling_for(tenant_id) when is_binary(tenant_id) do
    case Llm.chat_provider(tenant_id) do
      :openai_compatible -> OpenAiLLM
      :anthropic -> DefaultLLM
    end
  end

  @impl true
  def extract(scope_or_tenant_id, session_content, opts \\ []) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    sibling_for(scope.tenant_id).extract(scope, session_content, opts)
  end
end
