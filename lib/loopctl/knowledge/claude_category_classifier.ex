defmodule Loopctl.Knowledge.ClaudeCategoryClassifier do
  @moduledoc """
  Anthropic Claude-backed implementation of `Loopctl.Knowledge.ClassifierBehaviour`.

  Reuses the shared `:anthropic_provider` config (same key as the extractors).
  When no API key is configured it returns `{:error, :not_configured}` so the
  reclassification backfill degrades gracefully (it never mutates data with a
  placeholder verdict) in environments without Anthropic access.

  Only ACTIVE categories are ever returned — the model is never offered the
  retired `convention`, so a reclassification can only move an article ONTO the
  current taxonomy.
  """

  @behaviour Loopctl.Knowledge.ClassifierBehaviour

  require Logger

  alias Loopctl.Knowledge.Categories

  @system_prompt """
  You classify one knowledge-base article into exactly one category. Allowed \
  categories: #{Enum.join(Categories.active_strings(), ", ")}. Their meanings: \
  #{Categories.prompt_fragment()}. Reply with a single compact JSON object that \
  has exactly two keys: "category" (one of the allowed values above) and \
  "confidence" (a number from 0 to 1 for how sure you are). Output nothing \
  except that JSON object.\
  """

  @max_body_chars 16_000

  @impl true
  def classify(title, body) do
    config = Application.get_env(:loopctl, :anthropic_provider, %{})
    api_key = config[:api_key] || ""

    if api_key == "" do
      {:error, :not_configured}
    else
      call_anthropic(title, body, config)
    end
  end

  defp call_anthropic(title, body, config) do
    base_url = config[:base_url] || "https://api.anthropic.com/v1"

    # Classification can use a STRONGER model than content extraction without
    # changing extraction: :knowledge_classifier_model wins, else the shared
    # provider model, else Haiku. Set ANTHROPIC_CLASSIFIER_MODEL in prod to
    # override (e.g. a Sonnet id) for the one-time 77k reclassification.
    model =
      Application.get_env(:loopctl, :knowledge_classifier_model) ||
        config[:model] || "claude-haiku-4-5-20251001"

    user_content = "Title: #{title}\n\nBody:\n#{String.slice(body || "", 0, @max_body_chars)}"

    req_body = %{
      model: model,
      max_tokens: 100,
      system: @system_prompt,
      messages: [%{role: "user", content: user_content}]
    }

    case Req.post("#{base_url}/messages",
           json: req_body,
           headers: [
             {"x-api-key", config[:api_key]},
             {"anthropic-version", "2023-06-01"}
           ]
         ) do
      {:ok, %{status: 200, body: resp}} ->
        parse_text(get_in(resp, ["content", Access.at(0), "text"]))

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
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
