defmodule Loopctl.Knowledge.ClaudeContentExtractor do
  @moduledoc """
  Anthropic Claude-powered content extractor.

  Calls the Anthropic Messages API to extract structured knowledge articles
  from raw content (web articles, newsletters, skill templates, etc.).

  ## Per-tenant BYO (Epic 28 residual, #179)

  The Anthropic key + extraction model are resolved PER TENANT via
  `Loopctl.Llm.resolve(tenant_id, :extraction)` — each tenant supplies its own
  key and pays Anthropic directly. A tenant with no key gets `{:error,
  :no_api_key}` (mandatory BYO — no global fallback). Token usage is recorded
  after a successful call. The shared `Loopctl.Llm.Anthropic` client owns the
  resolve → POST → record_usage flow.
  """

  @behaviour Loopctl.Knowledge.ContentExtractorBehaviour

  require Logger

  alias Loopctl.Knowledge.Categories
  alias Loopctl.Llm.Anthropic
  alias Loopctl.SystemConfig

  @system_prompt """
  You are a knowledge extraction assistant. Given raw content (web article, \
  newsletter, skill template, etc.), extract reusable knowledge articles. \
  Return a JSON array of articles, each with: title (string), body (string, \
  markdown), category, and tags (array of short lowercase strings). The category \
  must be one of: #{Enum.join(Categories.active_strings(), ", ")}. Choose it by \
  these definitions -- #{Categories.prompt_fragment()}. Extract only genuinely \
  reusable knowledge -- skip promotional content, navigation, boilerplate. Max 10 \
  articles per input. Return ONLY the JSON array, no surrounding text or markdown \
  fences.\
  """

  @impl true
  def extract_from_content(tenant_id, content, opts \\ []) do
    source_type = Keyword.get(opts, :source_type, "unknown")

    body_fun = fn _model ->
      %{
        max_tokens: 64_000,
        system: @system_prompt,
        messages: [
          %{
            role: "user",
            content: "Source type: #{source_type}\n\nContent:\n#{content}"
          }
        ]
      }
    end

    # Explicit client budget UNDER the worker's per_chunk_timeout_ms/0 (60s
    # default) Oban budget (review #9) — the highest-max_tokens (64k) site, so
    # don't rely on the shared default. Both knobs are DB-backed and live-tunable
    # via Loopctl.SystemConfig; the in-code defaults below match the seeded rows
    # and apply on a cache miss (safe degrade). 25s keeps a single attempt inside
    # the per-chunk budget.
    #
    # ONE bounded transient retry (2026-07-10): under a harvest burst the provider
    # throttles and a single fast `:transport_error` / 429 was discarding the whole
    # multi-chunk ingestion job (then Oban re-ran the entire idempotent job — costly
    # and often failing all 3 attempts). `retry: :transient` is always set by
    # Anthropic.message; max_retries: 1 lets Req re-attempt once (~1s backoff) so the
    # COMMON fast-transient failure self-heals within the per-chunk budget. A slow
    # (~25s) first failure still can't fit a retry — unchanged, no regression — but
    # those are the minority.
    case Anthropic.message(tenant_id, :extraction, body_fun, %{source_type: source_type},
           receive_timeout: SystemConfig.get_int("extraction_receive_timeout_ms", 25_000),
           max_retries: SystemConfig.get_int("extraction_max_retries", 1)
         ) do
      {:ok, text} -> parse_articles(text)
      {:error, :no_api_key} -> {:error, :no_api_key}
      {:error, _} = err -> err
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
        # Attempt truncated JSON recovery before giving up
        case recover_truncated_json(text) do
          {:ok, articles} ->
            Logger.info(
              "ClaudeContentExtractor: recovered #{length(articles)} articles from truncated JSON"
            )

            {:ok, articles}

          :error ->
            Logger.warning("ClaudeContentExtractor: JSON parse error (error=#{inspect(reason)})")

            {:error, {:json_parse_error, reason}}
        end
    end
  end

  # Accept any DB-valid category (active + retired) so a stray `convention` from
  # the model isn't dropped; the prompt only offers active categories.
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
        metadata: %{"extraction_source" => "claude_content_extractor"}
      }
    else
      nil
    end
  end

  defp normalize_article(_), do: nil

  # Attempt to recover articles from truncated JSON by finding the last
  # complete object in the array. Works when the LLM response was cut off
  # mid-JSON due to max_tokens limit.
  defp recover_truncated_json(text) do
    # Find the last complete "}" that could end an article object
    # by progressively trimming from the end until we get valid JSON
    text = String.trim(text)

    # Ensure it starts with [ (an array)
    text =
      if String.starts_with?(text, "[") do
        text
      else
        # Maybe wrapped in {"articles": [...]}
        case Regex.run(~r/\[.*$/s, text) do
          [match] -> match
          _ -> text
        end
      end

    recover_by_closing_array(text)
  end

  defp recover_by_closing_array(text) do
    # Find positions of all "}" characters (potential object endings)
    # Try closing the array after each one, from last to first
    brace_positions =
      Regex.scan(~r/\}/, text, return: :index)
      |> Enum.map(fn [{pos, _}] -> pos end)
      |> Enum.reverse()

    Enum.find_value(brace_positions, :error, fn pos ->
      candidate = String.slice(text, 0, pos + 1) <> "]"
      try_parse_candidate(candidate)
    end)
  end

  defp try_parse_candidate(candidate) do
    case JSON.decode(candidate) do
      {:ok, articles} when is_list(articles) and articles != [] ->
        normalized =
          articles
          |> Enum.take(10)
          |> Enum.map(&normalize_article/1)
          |> Enum.filter(&(&1 != nil))

        if normalized != [], do: {:ok, normalized}

      _ ->
        nil
    end
  end

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
