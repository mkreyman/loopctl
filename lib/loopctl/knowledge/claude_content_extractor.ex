defmodule Loopctl.Knowledge.ClaudeContentExtractor do
  @moduledoc """
  Anthropic Claude-powered content extractor.

  Calls the Anthropic Messages API to extract structured knowledge articles
  from raw content (web articles, newsletters, skill templates, etc.).

  ## Configuration

  Set the following in runtime config (via `ANTHROPIC_API_KEY` env var):

      config :loopctl, :anthropic_provider, %{
        api_key: "sk-ant-...",
        base_url: "https://api.anthropic.com/v1",
        model: "claude-haiku-4-5-20251001"
      }
  """

  @behaviour Loopctl.Knowledge.ContentExtractorBehaviour

  require Logger

  @system_prompt """
  You are a knowledge extraction assistant. Given raw content (web article, \
  newsletter, skill template, etc.), extract reusable knowledge articles. \
  Return a JSON array of articles, each with: title (string), body (string, \
  markdown), category (one of: pattern, convention, decision, finding, reference), \
  tags (array of short lowercase strings). Extract only genuinely reusable \
  knowledge -- skip promotional content, navigation, boilerplate. Max 10 articles \
  per input. Return ONLY the JSON array, no surrounding text or markdown fences.\
  """

  @impl true
  def extract_from_content(content, opts \\ []) do
    config = Application.get_env(:loopctl, :anthropic_provider, %{})
    api_key = config[:api_key] || ""
    base_url = config[:base_url] || "https://api.anthropic.com/v1"
    model = config[:model] || "claude-haiku-4-5-20251001"

    source_type = Keyword.get(opts, :source_type, "unknown")

    body = %{
      model: model,
      max_tokens: 4096,
      system: @system_prompt,
      messages: [
        %{
          role: "user",
          content: "Source type: #{source_type}\n\nContent:\n#{content}"
        }
      ]
    }

    case Req.post("#{base_url}/messages",
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           retry: :transient,
           max_retries: 2,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        parse_articles(text)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "ClaudeContentExtractor: API error " <>
            "(status=#{status}, body=#{inspect(resp_body)})"
        )

        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning("ClaudeContentExtractor: request failed (error=#{inspect(reason)})")

        {:error, {:request_failed, reason}}
    end
  end

  defp parse_articles(text) do
    text = strip_markdown_fences(text)

    case JSON.decode(text) do
      {:ok, articles} when is_list(articles) ->
        normalized =
          articles
          |> Enum.take(10)
          |> Enum.map(&normalize_article/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, normalized}

      {:ok, %{"articles" => articles}} when is_list(articles) ->
        normalized =
          articles
          |> Enum.take(10)
          |> Enum.map(&normalize_article/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, normalized}

      {:ok, _other} ->
        Logger.warning("ClaudeContentExtractor: unexpected JSON structure")
        {:ok, []}

      {:error, reason} ->
        Logger.warning("ClaudeContentExtractor: JSON parse error (error=#{inspect(reason)})")

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
        metadata: %{"extraction_source" => "claude_content_extractor"}
      }
    else
      nil
    end
  end

  defp normalize_article(_), do: nil

  # Strip markdown code fences that Claude often wraps JSON in
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
