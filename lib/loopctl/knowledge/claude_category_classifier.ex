defmodule Loopctl.Knowledge.ClaudeCategoryClassifier do
  @moduledoc """
  Anthropic Claude-backed implementation of `Loopctl.Knowledge.ClassifierBehaviour`.

  Per-tenant BYO (Epic 28 residual, #179): the Anthropic key + classification
  model are resolved via `Loopctl.Llm.resolve(tenant_id, :classification)`. When
  the tenant has no key it returns `{:error, :no_api_key}` so the reclassification
  backfill degrades gracefully (it never mutates data with a placeholder verdict).
  Token usage is recorded after a successful call via the shared
  `Loopctl.Llm.Anthropic` client.

  Only ACTIVE categories are ever returned — the model is never offered the
  retired `convention`, so a reclassification can only move an article ONTO the
  current taxonomy.
  """

  @behaviour Loopctl.Knowledge.ClassifierBehaviour

  require Logger

  alias Loopctl.Knowledge.Categories
  alias Loopctl.Llm.Anthropic

  @system_prompt """
  You classify one knowledge-base article into exactly one category. Allowed \
  categories: #{Enum.join(Categories.active_strings(), ", ")}. Their meanings: \
  #{Categories.prompt_fragment()}. Choose the MOST SPECIFIC fit, and do not \
  over-use 'playbook': pick 'playbook' only when the article actually lays out \
  explicit ordered steps. If it states a principle, realization, or mental model, \
  use 'insight'; if it describes a reusable shape or recurring structure, use \
  'pattern'; if it proposes something to build or try, use 'idea'. Reply with a \
  single compact JSON object that has exactly two keys: "category" (one of the \
  allowed values above) and "confidence" (a number from 0 to 1 for how sure you \
  are). Output nothing except that JSON object.\
  """

  @max_body_chars 16_000

  @doc """
  The classification system prompt.

  Public so the OpenAI-compatible sibling
  (`Loopctl.Knowledge.OpenAiCategoryClassifier`) shares it rather than keeping a
  copy that drifts (US-41.3).
  """
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "The user message for a `(title, body)` pair — shared with the sibling impl."
  @spec user_content(String.t(), String.t() | nil) :: String.t()
  def user_content(title, body),
    do: "Title: #{title}\n\nBody:\n#{String.slice(body || "", 0, @max_body_chars)}"

  @impl true
  def classify(scope_or_tenant_id, title, body, opts \\ []) do
    user_content = user_content(title, body)

    body_fun = fn _model ->
      %{
        max_tokens: 100,
        system: @system_prompt,
        messages: [%{role: "user", content: user_content}]
      }
    end

    case classify_via(scope_or_tenant_id, opts, body_fun) do
      {:ok, text} -> parse_text(text)
      {:error, :no_api_key} -> {:error, :no_api_key}
      {:error, _} = err -> err
    end
  end

  # Use pre-resolved credentials when the caller supplied them (batched callers
  # resolve once — review #19); otherwise resolve per call.
  defp classify_via(scope_or_tenant_id, opts, body_fun) do
    case {opts[:api_key], opts[:model]} do
      {api_key, model} when is_binary(api_key) and is_binary(model) ->
        Anthropic.call(scope_or_tenant_id, :classification, api_key, model, body_fun)

      _ ->
        Anthropic.message(scope_or_tenant_id, :classification, body_fun)
    end
  end

  @doc """
  Parses an LLM response into a validated classification.

  Tolerant of the common ways a model wraps its JSON — markdown fences, a
  preamble, or trailing prose — by extracting the first `{...}` object from the
  text. Returns `{:error, :unparseable_classification}` for anything that isn't
  a JSON object with a valid active `category` and a numeric `confidence`
  (including the failure mode where the model echoes a `"<one of: ...>"`
  template literally). Public so the validation is unit-testable without HTTP.
  """
  @spec parse_text(String.t() | nil) ::
          {:ok, Loopctl.Knowledge.ClassifierBehaviour.result()}
          | {:error, :unparseable_classification}
  def parse_text(text) when is_binary(text) do
    with {:ok, json} <- extract_json_object(text),
         %{"category" => category, "confidence" => confidence} <- json,
         true <- category in Categories.active_strings(),
         true <- is_number(confidence) do
      {:ok, %{category: String.to_existing_atom(category), confidence: confidence / 1}}
    else
      _ -> {:error, :unparseable_classification}
    end
  end

  def parse_text(_), do: {:error, :unparseable_classification}

  defp extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, String.trim(text)) do
      [json] -> Jason.decode(json)
      _ -> :error
    end
  end
end
