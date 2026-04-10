defmodule Loopctl.Knowledge.LlmExtractor do
  @moduledoc """
  LLM-powered implementation of `ExtractorBehaviour`.

  Calls the Anthropic Messages API to extract knowledge articles from
  review contexts. Given a code review context (findings, fixes, summary),
  extracts reusable knowledge articles about patterns, conventions, or
  decisions that would help future code reviews.

  ## Configuration

  Uses the `:anthropic_provider` config key (shared with `ClaudeContentExtractor`):

      config :loopctl, :anthropic_provider, %{
        api_key: "sk-ant-...",
        base_url: "https://api.anthropic.com/v1",
        model: "claude-haiku-4-5-20251001"
      }

  When no API key is configured, falls back to returning an empty list
  (graceful degradation for dev/test environments without Anthropic access).
  """

  @behaviour Loopctl.Knowledge.ExtractorBehaviour

  require Logger

  @system_prompt """
  You are a code review knowledge extractor. Given a code review context \
  (review type, findings count, fixes count, summary), extract reusable \
  knowledge articles about patterns, conventions, or decisions that would \
  help future code reviews. Return a JSON array of articles, each with: \
  title (string), body (string, markdown), category (one of: pattern, \
  convention, decision, finding, reference), tags (array of short lowercase \
  strings). Extract only genuinely reusable knowledge. Max 5 articles per \
  review. Return ONLY the JSON array, no surrounding text or markdown fences.\
  """

  @impl true
  def extract_articles(context) do
    config = Application.get_env(:loopctl, :anthropic_provider, %{})
    api_key = config[:api_key] || ""

    if api_key == "" do
      Logger.debug("LlmExtractor: no Anthropic API key configured, returning empty list")
      {:ok, []}
    else
      call_anthropic(context, config)
    end
  end

  defp call_anthropic(context, config) do
    base_url = config[:base_url] || "https://api.anthropic.com/v1"
    model = config[:model] || "claude-haiku-4-5-20251001"

    user_message = build_user_message(context)

    body = %{
      model: model,
      max_tokens: 2048,
      system: @system_prompt,
      messages: [%{role: "user", content: user_message}]
    }

    case Req.post("#{base_url}/messages",
           json: body,
           headers: [
             {"x-api-key", config[:api_key]},
             {"anthropic-version", "2023-06-01"}
           ],
           retry: :transient,
           max_retries: 2,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        parse_articles(text)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("LlmExtractor: API error (status=#{status}, body=#{inspect(resp_body)})")

        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning("LlmExtractor: request failed (error=#{inspect(reason)})")
        {:error, {:request_failed, reason}}
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

  @valid_categories ~w(pattern convention decision finding reference)

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
