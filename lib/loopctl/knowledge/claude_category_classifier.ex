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
  You classify one knowledge-base article into exactly one category. The \
  categories and their meanings are: #{Categories.prompt_fragment()}. Respond \
  with ONLY a JSON object of the form \
  {"category": "<one of: #{Enum.join(Categories.active_strings(), ", ")}>", \
  "confidence": <number between 0 and 1>}. `confidence` is how sure you are of \
  the category. No prose, no markdown fences.\
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
    model = config[:model] || "claude-haiku-4-5-20251001"

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
      {:ok, %{status: 200, body: resp}} -> parse_response(resp)
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response(resp) do
    with text when is_binary(text) <- get_in(resp, ["content", Access.at(0), "text"]),
         {:ok, decoded} <- Jason.decode(String.trim(text)),
         %{"category" => category, "confidence" => confidence} <- decoded,
         true <- category in Categories.active_strings(),
         true <- is_number(confidence) do
      {:ok, %{category: String.to_existing_atom(category), confidence: confidence / 1}}
    else
      _ -> {:error, :unparseable_classification}
    end
  end
end
