defmodule Loopctl.Knowledge.ExtractorRouter do
  @moduledoc """
  Tenant-aware router for `Loopctl.Knowledge.ExtractorBehaviour` (review-context
  knowledge extraction) — US-41.3, AC-41.3.2.

  The module named by `config :loopctl, :knowledge_extractor, ...` stays the
  SINGLE resolution point (resolved at call time via `Application.get_env`); it is
  now this router, which dispatches per call to the Anthropic or OpenAI-compatible
  sibling based on TENANT settings. `config/test.exs`'s Mox mapping is untouched.

  Provider choice is tenant DATA, not deployment config, so `sibling_for/1`
  resolves per call — deliberately NOT `Application.compile_env`. See
  `Loopctl.Knowledge.ContentExtractorRouter` for the full rationale.
  """

  @behaviour Loopctl.Knowledge.ExtractorBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.LlmExtractor
  alias Loopctl.Knowledge.OpenAiExtractor
  alias Loopctl.Llm

  @doc "The sibling impl this tenant's calls dispatch to (TC-41.3.1)."
  @spec sibling_for(Ecto.UUID.t()) :: module()
  def sibling_for(tenant_id) when is_binary(tenant_id) do
    case Llm.chat_provider(tenant_id) do
      :openai_compatible -> OpenAiExtractor
      :anthropic -> LlmExtractor
    end
  end

  @impl true
  def extract_articles(scope_or_tenant_id, context) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    sibling_for(scope.tenant_id).extract_articles(scope, context)
  end
end
