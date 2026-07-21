defmodule Loopctl.Knowledge.OpenAiCategoryClassifier do
  @moduledoc """
  OpenAI-compatible SIBLING of `Loopctl.Knowledge.ClaudeCategoryClassifier`
  (US-41.3, AC-41.3.2).

  ## The pre-resolved-credential batch path

  `ClaudeCategoryClassifier` accepts `opts[:api_key]` / `opts[:model]` so a batch
  caller resolves ONCE. That path is a cross-provider credential-leak vector: the
  batch caller resolved against ITS provider, and blindly forwarding those
  credentials here would ship an Anthropic key to a tenant-supplied host.

  This impl therefore IGNORES pre-resolved `opts` credentials entirely and always
  resolves its own OpenAI-compatible target. The cost is one cached settings read
  per call (`Loopctl.Llm.get_settings/1` is ETS-cached read-through, so it is not
  a DB round-trip); the benefit is that the leak is structurally impossible rather
  than conventionally avoided.

  Shape validation (AC-41.3.4) reuses the Anthropic impl's `parse_text/1` — which
  already returns a legible `{:error, :unparseable_classification}` for prose —
  and UPGRADES it to a `Loopctl.Llm.ShapeError` naming the endpoint and the model.
  """

  @behaviour Loopctl.Knowledge.ClassifierBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeCategoryClassifier
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.Llm.ShapeError

  @impl true
  def classify(scope_or_tenant_id, title, body, _opts \\ []) do
    scope = EgressScope.coerce(scope_or_tenant_id)

    with {:ok, target} <- OpenAiChat.resolve_target(scope.tenant_id, :classification),
         {:ok, text} <- request(scope, target, title, body) do
      parse(text, target)
    end
  end

  defp request(scope, target, title, body) do
    body_fun = fn _model ->
      %{
        max_tokens: 100,
        system: ClaudeCategoryClassifier.system_prompt(),
        messages: [
          %{role: "user", content: ClaudeCategoryClassifier.user_content(title, body)}
        ]
      }
    end

    OpenAiChat.call(
      scope,
      :classification,
      target.base_url,
      target.api_key,
      target.model,
      body_fun
    )
  end

  defp parse(text, target) do
    case ClaudeCategoryClassifier.parse_text(text) do
      {:ok, result} ->
        {:ok, result}

      {:error, :unparseable_classification} ->
        {:error,
         ShapeError.new(
           target.endpoint,
           target.model,
           :missing_required_fields,
           ~s|expected a JSON object with "category" and numeric "confidence"|
         )}
    end
  end
end
