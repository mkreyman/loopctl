defmodule Loopctl.Knowledge.LlmExtractor do
  @moduledoc """
  LLM-powered implementation of `ExtractorBehaviour`.

  Calls the Anthropic Messages API to extract knowledge articles from
  review contexts. Given a code review context (findings, fixes, summary),
  extracts reusable knowledge articles about patterns, conventions, or
  decisions that would help future code reviews.

  ## Per-tenant BYO (Epic 28, #179)

  The Anthropic key + extraction model are resolved PER TENANT via
  `Loopctl.Llm.resolve(tenant_id, :extraction)` — each tenant supplies its own
  key and pays Anthropic directly. A tenant with no key gets `{:error,
  :no_api_key}` (mandatory BYO — no global-system-key fallback). Token usage is
  recorded after a successful call. The shared `Loopctl.Llm.Anthropic` client
  owns the resolve → POST → record_usage flow.
  """

  @behaviour Loopctl.Knowledge.ExtractorBehaviour

  require Logger

  alias Loopctl.Knowledge.Categories
  alias Loopctl.Llm.Anthropic

  # This review-extraction call has no tight outer Oban timeout, but keep the
  # client budget bounded (review #5).
  @receive_timeout 55_000
  @max_retries 1

  @system_prompt """
  You are a code review knowledge extractor. Given a code review context \
  (review type, findings count, fixes count, summary), extract reusable \
  knowledge articles that would help future code reviews. Return a JSON array \
  of articles, each with: title (string), body (string, markdown), category, \
  and tags (array of short lowercase strings). The category must be one of: \
  #{Enum.join(Categories.active_strings(), ", ")}. Choose it by these \
  definitions -- #{Categories.prompt_fragment()}. Extract only genuinely \
  reusable knowledge. Max 5 articles per review. Return ONLY the JSON array, \
  no surrounding text or markdown fences.\
  """

  @impl true
  def extract_articles(scope_or_tenant_id, context) do
    user_message = build_user_message(context)

    body_fun = fn _model ->
      %{
        max_tokens: 16_384,
        system: @system_prompt,
        messages: [%{role: "user", content: user_message}]
      }
    end

    case Anthropic.message(
           scope_or_tenant_id,
           :extraction,
           body_fun,
           %{source_type: "review_finding"},
           receive_timeout: @receive_timeout,
           max_retries: @max_retries
         ) do
      {:ok, text} -> parse_articles(text)
      {:error, :no_api_key} -> {:error, :no_api_key}
      {:error, _} = err -> err
    end
  end

  defp build_user_message(context) do
    """
    Review Context:
    - Review type: #{context[:review_type] || "unknown"}
    - Findings: #{context[:findings_count] || 0}
    - Fixes: #{context[:fixes_count] || 0}
    - Summary: #{context[:summary] || "No summary provided"}
    """
  end

  defp parse_articles(text) do
    text = strip_markdown_fences(text)

    case JSON.decode(text) do
      {:ok, articles} when is_list(articles) ->
        normalized =
          articles
          |> Enum.take(5)
          |> Enum.map(&normalize_article/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, normalized}

      {:ok, %{"articles" => articles}} when is_list(articles) ->
        normalized =
          articles
          |> Enum.take(5)
          |> Enum.map(&normalize_article/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, normalized}

      {:ok, _other} ->
        Logger.warning("LlmExtractor: unexpected JSON structure")
        {:ok, []}

      {:error, reason} ->
        Logger.warning("LlmExtractor: JSON parse error (error=#{inspect(reason)})")
        {:error, {:json_parse_error, reason}}
    end
  end

  # Accept any DB-valid category (active + retired); the prompt only offers active.
  @valid_categories Categories.all_strings()

  defp normalize_article(article) when is_map(article) do
    title = article["title"]
    body = article["body"]
    category = article["category"]
    tags = article["tags"] || []

    if is_binary(title) and title != "" and is_binary(body) and category in @valid_categories do
      %{
        title: title,
        body: body,
        category: String.to_existing_atom(category),
        tags: normalize_tags(tags),
        metadata: %{"extraction_source" => "llm_review_extractor"}
      }
    else
      nil
    end
  end

  defp normalize_article(_), do: nil

  defp strip_markdown_fences(text) do
    text
    |> String.trim()
    |> then(fn t ->
      if String.starts_with?(t, "```") do
        t
        |> String.replace(~r/\A```(?:json)?\s*\n?/, "")
        |> String.replace(~r/\n?```\s*\z/, "")
      else
        t
      end
    end)
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.take(20)
  end

  defp normalize_tags(_), do: []
end
