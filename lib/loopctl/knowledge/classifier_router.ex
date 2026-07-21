defmodule Loopctl.Knowledge.ClassifierRouter do
  @moduledoc """
  Tenant-aware router for `Loopctl.Knowledge.ClassifierBehaviour` (US-41.3,
  AC-41.3.2).

  The module named by `config :loopctl, :category_classifier, ...` stays the
  SINGLE resolution point; it is now this router, dispatching per call to the
  Anthropic or OpenAI-compatible sibling based on TENANT settings.
  `config/test.exs`'s Mox mapping is untouched.

  ## The pre-resolved-credential batch path

  `Loopctl.Workers.KnowledgeReclassifyWorker` resolves credentials ONCE and passes
  `opts[:api_key]` / `opts[:model]` to save a per-article resolve. Those
  credentials belong to whichever provider the BATCH resolved. The router
  therefore resolves the PROVIDER FIRST and only then forwards; the
  OpenAI-compatible sibling additionally IGNORES pre-resolved opts credentials
  entirely and resolves its own, so an Anthropic key can never reach a
  tenant-supplied host even if a future caller forwards one.

  Provider choice is tenant DATA, not deployment config — see
  `Loopctl.Knowledge.ContentExtractorRouter` for the full rationale.
  """

  @behaviour Loopctl.Knowledge.ClassifierBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeCategoryClassifier
  alias Loopctl.Knowledge.OpenAiCategoryClassifier
  alias Loopctl.Llm

  @doc "The sibling impl this tenant's calls dispatch to (TC-41.3.1)."
  @spec sibling_for(Ecto.UUID.t()) :: module()
  def sibling_for(tenant_id) when is_binary(tenant_id) do
    case Llm.chat_provider(tenant_id) do
      :openai_compatible -> OpenAiCategoryClassifier
      :anthropic -> ClaudeCategoryClassifier
    end
  end

  @impl true
  def classify(scope_or_tenant_id, title, body, opts \\ []) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    sibling_for(scope.tenant_id).classify(scope, title, body, opts)
  end
end
