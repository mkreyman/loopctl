defmodule Loopctl.Knowledge.StrictArticleParser do
  @moduledoc """
  STRICT article-list parsing for the OpenAI-compatible extraction path
  (US-41.3, AC-41.3.4).

  The Anthropic-era parsers
  (`Loopctl.Knowledge.ClaudeContentExtractor`/`LlmExtractor`) are deliberately
  TOLERANT: a non-array JSON body becomes `{:ok, []}` and any element that fails
  `normalize_article/1` is silently dropped. That was calibrated for a model that
  reliably returns the requested structure — a rare miss degrading to "no
  articles" is the right trade there.

  It is the WRONG trade for a tenant-supplied local model, which is materially
  weaker at structured output. Silently returning `{:ok, []}` reports "there was
  nothing reusable in your document" when the truth is "your model cannot produce
  the required structure", and dropping half the items writes an arbitrary subset
  of a malformed response. So on this path:

    * anything that is not a JSON array (or `{"articles": [...]}`) fails;
    * a NON-EMPTY list in which no element validates fails;
    * a list in which SOME elements are invalid fails — a partial write is worse
      than a legible refusal, because nothing downstream can tell the difference
      between "the model found 2 things" and "the model mangled 8 of 10";
    * an EXPLICIT empty array `[]` is honoured as `{:ok, []}` — the model
      correctly produced the structure and found nothing reusable.

  Every failure is a `Loopctl.Llm.ShapeError` naming the endpoint and the model,
  and is PERMANENT (never retried blindly).

  ## Truncation is NOT a shape failure

  A response cut off mid-array by `max_tokens` is a TOKEN-BUDGET artifact, not the
  "your model cannot produce the structure" configuration problem this module
  reports — and local models, with smaller context windows, hit it MORE often than
  Claude. `Loopctl.Knowledge.ClaudeContentExtractor` recovers those by closing the
  array after the last complete object; dropping that recovery here would
  permanently `{:discard}` a tenant's chunk (via `permanent_error?/1`) that the
  Anthropic path would have salvaged, under a misleading "this is a CONFIGURATION
  problem" message. So truncation is recovered the same way, and only an
  UNRECOVERABLE truncation is reported — as its own `:truncated_json` reason whose
  remediation is the token budget, distinct from `:not_json` (the model answered
  prose).
  """

  require Logger

  alias Loopctl.Knowledge.Categories
  alias Loopctl.Llm.ShapeError

  # Accept any DB-valid category (active + retired) so a stray `convention` isn't
  # rejected; the prompts only offer active categories. Mirrors the Anthropic impls.
  @valid_categories Categories.all_strings()

  @typedoc "Where the parse happened, for the shape-error reason."
  @type target :: %{
          endpoint: String.t(),
          model: String.t(),
          max_articles: pos_integer(),
          extraction_source: String.t()
        }

  @doc """
  Parses `text` into normalized article attrs, or a `ShapeError`.

  `target` names the endpoint + model (for the error), the article cap and the
  `metadata.extraction_source` marker to stamp on each article.
  """
  @spec parse(String.t() | nil, target()) ::
          {:ok, [map()]} | {:error, ShapeError.t()}
  def parse(text, %{endpoint: endpoint, model: model} = target) when is_binary(text) do
    stripped = strip_markdown_fences(text)

    case JSON.decode(stripped) do
      {:ok, articles} when is_list(articles) ->
        normalize_all(articles, target)

      {:ok, %{"articles" => articles}} when is_list(articles) ->
        normalize_all(articles, target)

      {:ok, _other} ->
        {:error,
         ShapeError.new(endpoint, model, :not_a_list, "expected a JSON array of article objects")}

      {:error, _reason} ->
        undecodable(stripped, target)
    end
  end

  def parse(_text, %{endpoint: endpoint, model: model}),
    do: {:error, ShapeError.new(endpoint, model, :not_json, "the response was not text")}

  # Text that did not decode. Either it was TRUNCATED mid-array (recoverable, and
  # the same recovery the Anthropic path performs) or it was never JSON at all.
  defp undecodable(text, %{endpoint: endpoint, model: model} = target) do
    case recover_truncated_json(text) do
      {:ok, articles} ->
        Logger.info(
          "StrictArticleParser: recovered #{length(articles)} articles from truncated JSON " <>
            "(endpoint=#{endpoint} model=#{model})"
        )

        normalize_all(articles, target)

      :error ->
        {:error, ShapeError.new(endpoint, model, reason_for(text), detail_for(text))}
    end
  end

  defp reason_for(text) do
    if json_ish?(text), do: :truncated_json, else: :not_json
  end

  defp detail_for(text) do
    if json_ish?(text) do
      "the response STARTS as the requested JSON but does not parse and no complete " <>
        "leading object could be recovered — the usual cause is the response being cut " <>
        "off at the model's max_tokens, not a structure the model cannot produce"
    else
      "the response was not JSON (a local model returning prose instead of the " <>
        "requested JSON array is the usual cause)"
    end
  end

  defp json_ish?(text), do: String.starts_with?(text, ["[", "{"])

  # Close the array after the last complete object, newest-first. Mirrors
  # `Loopctl.Knowledge.ClaudeContentExtractor.recover_truncated_json/1`; the
  # recovered list is then held to the SAME strict normalization as any other, so a
  # recovered element that is malformed still refuses rather than writing a partial.
  defp recover_truncated_json(text) do
    array =
      if String.starts_with?(text, "[") do
        text
      else
        case Regex.run(~r/\[.*$/s, text) do
          [match] -> match
          _ -> text
        end
      end

    ~r/\}/
    |> Regex.scan(array, return: :index)
    |> Enum.map(fn [{pos, _len}] -> pos end)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn pos ->
      case JSON.decode(String.slice(array, 0, pos + 1) <> "]") do
        {:ok, [_ | _] = articles} -> {:ok, articles}
        _ -> nil
      end
    end)
  end

  defp normalize_all([], _target), do: {:ok, []}

  defp normalize_all(articles, %{endpoint: endpoint, model: model} = target) do
    normalized =
      articles
      |> Enum.take(target.max_articles)
      |> Enum.map(&normalize_article(&1, target.extraction_source))

    cond do
      Enum.all?(normalized, &is_nil/1) ->
        {:error,
         ShapeError.new(
           endpoint,
           model,
           :no_valid_items,
           "no element carried a non-empty title + body and a valid category"
         )}

      Enum.any?(normalized, &is_nil/1) ->
        invalid = Enum.count(normalized, &is_nil/1)

        {:error,
         ShapeError.new(
           endpoint,
           model,
           :missing_required_fields,
           "#{invalid} of #{length(normalized)} items lacked a non-empty title + body or a " <>
             "valid category; refusing a PARTIAL write"
         )}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_article(article, extraction_source) when is_map(article) do
    title = article["title"]
    body = article["body"]
    category = article["category"]

    if is_binary(title) and String.trim(title) != "" and is_binary(body) and
         String.trim(body) != "" and category in @valid_categories do
      %{
        title: title,
        body: body,
        category: String.to_existing_atom(category),
        tags: normalize_tags(article["tags"] || []),
        metadata: %{"extraction_source" => extraction_source}
      }
    else
      nil
    end
  end

  defp normalize_article(_article, _extraction_source), do: nil

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.take(20)
  end

  defp normalize_tags(_tags), do: []

  # Local models wrap JSON in markdown fences even more eagerly than Claude does.
  defp strip_markdown_fences(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "```") do
      trimmed
      |> String.replace(~r/\A```(?:json)?\s*\n?/, "")
      |> String.replace(~r/\n?```\s*\z/, "")
    else
      trimmed
    end
  end
end
