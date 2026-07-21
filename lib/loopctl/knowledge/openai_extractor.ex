defmodule Loopctl.Knowledge.OpenAiExtractor do
  @moduledoc """
  OpenAI-compatible SIBLING of `Loopctl.Knowledge.LlmExtractor` (review-context
  knowledge extraction) — US-41.3, AC-41.3.2.

  Same behaviour and prompt (read from the Claude impl), routed to the tenant's
  own endpoint via `Loopctl.Llm.OpenAiChat`, with STRICT shape validation
  (AC-41.3.4). Selected per tenant by `Loopctl.Knowledge.ExtractorRouter`.
  """

  @behaviour Loopctl.Knowledge.ExtractorBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.LlmExtractor
  alias Loopctl.Knowledge.StrictArticleParser
  alias Loopctl.Llm.OpenAiChat

  @receive_timeout 55_000
  @max_retries 1
  @max_articles 5

  @impl true
  def extract_articles(scope_or_tenant_id, context) do
    scope = EgressScope.coerce(scope_or_tenant_id)

    with {:ok, target} <- OpenAiChat.resolve_target(scope.tenant_id, :extraction),
         {:ok, text} <- request(scope, target, context) do
      StrictArticleParser.parse(text, %{
        endpoint: target.endpoint,
        model: target.model,
        max_articles: @max_articles,
        extraction_source: "openai_review_extractor"
      })
    end
  end

  defp request(scope, target, context) do
    body_fun = fn _model ->
      %{
        max_tokens: 16_384,
        system: LlmExtractor.system_prompt(),
        messages: [%{role: "user", content: LlmExtractor.user_message(context)}]
      }
    end

    OpenAiChat.call(
      scope,
      :extraction,
      target.base_url,
      target.api_key,
      target.model,
      body_fun,
      %{source_type: "review_finding"},
      receive_timeout: @receive_timeout,
      max_retries: @max_retries
    )
  end
end
