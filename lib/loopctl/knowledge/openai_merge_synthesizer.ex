defmodule Loopctl.Knowledge.OpenAiMergeSynthesizer do
  @moduledoc """
  OpenAI-compatible SIBLING of `Loopctl.Knowledge.ClaudeMergeSynthesizer`
  (US-41.3, AC-41.3.2).

  Same behaviour and prompt (read from the Claude impl), routed to the tenant's
  own endpoint. A response that isn't a JSON object with a non-empty title + body
  fails with a `Loopctl.Llm.ShapeError` naming the endpoint and model rather than
  drafting a malformed merged article (AC-41.3.4).
  """

  @behaviour Loopctl.Knowledge.MergeSynthesizerBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeMergeSynthesizer
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.Llm.ShapeError

  @receive_timeout 55_000
  @max_retries 1

  @impl true
  def synthesize(scope_or_tenant_id, a, b) do
    scope = EgressScope.coerce(scope_or_tenant_id)

    with {:ok, target} <- OpenAiChat.resolve_target(scope.tenant_id, :merge),
         {:ok, text} <- request(scope, target, a, b) do
      parse(text, target)
    end
  end

  defp request(scope, target, a, b) do
    body_fun = fn _model ->
      %{
        max_tokens: 2000,
        system: ClaudeMergeSynthesizer.system_prompt(),
        messages: [%{role: "user", content: ClaudeMergeSynthesizer.user_content(a, b)}]
      }
    end

    OpenAiChat.call(
      scope,
      :merge,
      target.base_url,
      target.api_key,
      target.model,
      body_fun,
      %{},
      receive_timeout: @receive_timeout,
      max_retries: @max_retries
    )
  end

  defp parse(text, target) do
    case ClaudeMergeSynthesizer.parse_text(text) do
      {:ok, article} ->
        {:ok, article}

      {:error, :unparseable_merge} ->
        {:error,
         ShapeError.new(
           target.endpoint,
           target.model,
           :missing_required_fields,
           ~s|expected a JSON object with non-empty "title" and "body"|
         )}
    end
  end
end
