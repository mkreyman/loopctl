defmodule Loopctl.Knowledge.OpenAiContentExtractor do
  @moduledoc """
  OpenAI-compatible SIBLING of `Loopctl.Knowledge.ClaudeContentExtractor`
  (US-41.3, AC-41.3.2).

  Same behaviour, same prompt (read from the Claude impl so the two can never
  drift), same return contract. Two things differ:

    * the call goes through `Loopctl.Llm.OpenAiChat` against the tenant's OWN
      `chat_base_url` + `chat_api_key`, so the document's full text never leaves
      the tenant's chosen boundary;
    * parsing is STRICT (`Loopctl.Knowledge.StrictArticleParser`) — a local model
      that cannot produce the required JSON fails with a legible, endpoint- and
      model-naming `Loopctl.Llm.ShapeError` instead of silently yielding
      `{:ok, []}` or a partial write (AC-41.3.4).

  Never selected directly: `Loopctl.Knowledge.ContentExtractorRouter` is the
  module named in config and dispatches here per tenant.
  """

  @behaviour Loopctl.Knowledge.ContentExtractorBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeContentExtractor
  alias Loopctl.Knowledge.StrictArticleParser
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.SystemConfig

  @max_articles 10

  @impl true
  def extract_from_content(scope_or_tenant_id, content, opts \\ []) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    source_type = Keyword.get(opts, :source_type, "unknown")
    source_ref = Keyword.get(opts, :source_ref)

    # Resolve the PROVIDER + endpoint + model FIRST so a shape failure can name
    # them, and so no Anthropic credential can be handed to this client.
    with {:ok, target} <- OpenAiChat.resolve_target(scope.tenant_id, :extraction),
         {:ok, text} <- request(scope, target, content, source_type, source_ref) do
      StrictArticleParser.parse(text, %{
        endpoint: target.endpoint,
        model: target.model,
        max_articles: @max_articles,
        extraction_source: "openai_content_extractor"
      })
    end
  end

  defp request(scope, target, content, source_type, source_ref) do
    body_fun = fn _model ->
      %{
        max_tokens: 64_000,
        system: ClaudeContentExtractor.system_prompt(),
        messages: [
          %{
            role: "user",
            content: ClaudeContentExtractor.user_content(content, source_type, source_ref)
          }
        ]
      }
    end

    # Same live-tunable budget knobs as the Anthropic path: the outer per-chunk
    # Oban budget is provider-independent, so the client budget must be too.
    OpenAiChat.call(
      scope,
      :extraction,
      target.base_url,
      target.api_key,
      target.model,
      body_fun,
      %{source_type: source_type},
      receive_timeout: SystemConfig.get_int("extraction_receive_timeout_ms", 25_000),
      max_retries: SystemConfig.get_int("extraction_max_retries", 1)
    )
  end
end
