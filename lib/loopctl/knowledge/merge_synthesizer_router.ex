defmodule Loopctl.Knowledge.MergeSynthesizerRouter do
  @moduledoc """
  Tenant-aware router for `Loopctl.Knowledge.MergeSynthesizerBehaviour` (US-41.3,
  AC-41.3.2).

  The module named by `config :loopctl, :merge_synthesizer, ...` stays the SINGLE
  resolution point; it is now this router, dispatching per call to the Anthropic
  or OpenAI-compatible sibling based on TENANT settings. `config/test.exs`'s Mox
  mapping is untouched.

  Provider choice is tenant DATA, not deployment config — see
  `Loopctl.Knowledge.ContentExtractorRouter` for the full rationale.
  """

  @behaviour Loopctl.Knowledge.MergeSynthesizerBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeMergeSynthesizer
  alias Loopctl.Knowledge.OpenAiMergeSynthesizer
  alias Loopctl.Llm

  @doc "The sibling impl this tenant's calls dispatch to (TC-41.3.1)."
  @spec sibling_for(Ecto.UUID.t()) :: module()
  def sibling_for(tenant_id) when is_binary(tenant_id) do
    case Llm.chat_provider(tenant_id) do
      :openai_compatible -> OpenAiMergeSynthesizer
      :anthropic -> ClaudeMergeSynthesizer
    end
  end

  @impl true
  def synthesize(scope_or_tenant_id, a, b) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    sibling_for(scope.tenant_id).synthesize(scope, a, b)
  end
end
