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
    case text |> strip_markdown_fences() |> JSON.decode() do
      {:ok, articles} when is_list(articles) ->
        normalize_all(articles, target)

      {:ok, %{"articles" => articles}} when is_list(articles) ->
        normalize_all(articles, target)

      {:ok, _other} ->
        {:error,
         ShapeError.new(endpoint, model, :not_a_list, "expected a JSON array of article objects")}

      {:error, _reason} ->
        {:error,
         ShapeError.new(
           endpoint,
           model,
           :not_json,
           "the response was not JSON (a local model returning prose instead of the " <>
             "requested JSON array is the usual cause)"
         )}
    end
  end

  def parse(_text, %{endpoint: endpoint, model: model}),
    do: {:error, ShapeError.new(endpoint, model, :not_json, "the response was not text")}

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
