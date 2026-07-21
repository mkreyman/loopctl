defmodule Loopctl.Memory.Promoter.OpenAiLLM do
  @moduledoc """
  OpenAI-compatible SIBLING of `Loopctl.Memory.Promoter.DefaultLLM` (US-41.3,
  AC-41.3.2).

  Both AC-29.1.3 (determinism: `temperature: 0` + a FIXED system prompt) and
  AC-29.1.5 (injection hardening: untrusted session content framed by fixed
  delimiters that are neutralized in the content itself) are PRESERVED by reading
  the prompt and the framed user message from the Anthropic impl rather than
  copying them — a copy would let the hardening silently drift out of this path,
  which is precisely the path handling attacker-influenced content.

  The behaviour returns RAW TEXT (`Loopctl.Memory.Promoter` parses and validates
  it, capping every field and validating cross_links against the tenant), so
  shape validation for this surface lives in the promoter, not here. What this
  module adds is the client-level shape guarantee: a 200 that is not
  OpenAI-compatible fails as a `Loopctl.Llm.ShapeError` naming the endpoint and
  model rather than reaching the promoter as unusable text.
  """

  @behaviour Loopctl.Memory.Promoter.LLMBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.Memory.Promoter.DefaultLLM

  @impl true
  def extract(scope_or_tenant_id, session_content, _opts \\ []) when is_binary(session_content) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    params = DefaultLLM.request_params()

    body_fun = fn _model ->
      %{
        max_tokens: params.max_tokens,
        temperature: 0,
        system: DefaultLLM.system_prompt(),
        messages: [%{role: "user", content: DefaultLLM.user_content(session_content)}]
      }
    end

    with {:ok, target} <- OpenAiChat.resolve_target(scope.tenant_id, :extraction) do
      OpenAiChat.call(
        scope,
        :extraction,
        target.base_url,
        target.api_key,
        target.model,
        body_fun,
        %{},
        receive_timeout: params.receive_timeout,
        max_retries: params.max_retries
      )
    end
  end
end
