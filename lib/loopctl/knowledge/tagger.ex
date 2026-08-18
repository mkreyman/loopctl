defmodule Loopctl.Knowledge.Tagger do
  @moduledoc """
  Re-tags an existing article, preferring vocabulary the corpus already uses.

  ## The problem this exists for

  Tags are LLM-generated once at ingest and nothing ever revisited them, so each article's
  tags were invented in isolation. Measured on the hosted corpus 2026-08-17:

  | | |
  |---|---:|
  | topical tag instances | 684,883 |
  | distinct topical tags | 60,141 |
  | **used exactly once** | **33,234 (55.3%)** |
  | collapsible by pure normalisation (case/punctuation/plural) | 2,723 (4.5%) |

  More than half the vocabulary is singletons, and only 4.5% of that is spelling variants —
  the rest is genuinely different strings for related ideas. A tag used once groups nothing,
  and since tags entered `articles.search_vector` it also contributes an index lexeme that
  matches exactly one document.

  Coverage is NOT the problem: the corpus averages 8.66 topical tags per article and only 46
  published articles carry fewer than three. So a re-tagger that just generates more tags
  makes the fragmentation worse. **The whole point of this module is the vocabulary it is
  shown**: the tagger receives the tenant's established tags and is told to reuse them unless
  the article genuinely needs a new one.

  ## What a re-tag may and may not do

  It MERGES. Existing tags are never removed — an article's provenance ids, its
  `idem-` reservation and any hand-curated tag survive untouched, and the result is capped at
  `Article.max_tags/0`. A re-tagger that replaced tags could silently drop the idempotency key
  a sourcer depends on to know the article was already captured.
  """

  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ProvenanceTags

  @type article :: %{id: String.t(), title: String.t(), body: String.t(), tags: [String.t()]}

  @callback suggest(
              scope_or_tenant_id :: term(),
              article :: article(),
              vocabulary :: [String.t()],
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, term()}

  require Logger

  # The pattern `Loopctl.Knowledge.Article`'s changeset enforces (`~r/^[a-zA-Z0-9_-]+$/`),
  # narrowed to the lowercase form `normalize/1` produces. A suggestion the changeset would
  # reject is dropped HERE, so one malformed tag cannot fail the whole article's re-tag —
  # and, more importantly, cannot be written at all: `TagBackfillWorker` persists with
  # `update_all`, which runs no changeset, so an accepted-here tag lands unvalidated and
  # only surfaces later as a 422 on an unrelated caller's PATCH. No `.`: the changeset
  # rejects it, and the tagging prompt must not offer it either.
  @tag_pattern ~r/^[a-z0-9][a-z0-9_-]*$/
  @max_tag_length 64

  @doc """
  Suggest tags for `article` and return the MERGED tag list, or the unchanged list.

  Returns `{:ok, tags, added}` where `added` is what the suggestion contributed, or
  `{:error, reason}`. The caller decides whether an empty `added` is worth a write.
  """
  @spec retag(term(), article(), [String.t()], keyword()) ::
          {:ok, [String.t()], [String.t()]} | {:error, term()}
  def retag(scope_or_tenant_id, article, vocabulary, opts \\ []) do
    case impl(opts).suggest(scope_or_tenant_id, article, vocabulary, opts) do
      {:ok, suggested} ->
        {tags, added} = merge(article.tags, suggested)
        {:ok, tags, added}

      {:error, _} = error ->
        error
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Merge suggested tags into existing ones.

  Existing tags come FIRST and are never dropped: they carry provenance ids and the reserved
  `idem-` namespace a sourcer uses to know an article was already captured, and losing one
  causes a re-capture rather than a cosmetic regression. New tags fill the remaining room up
  to `Article.max_tags/0`, so a verbose suggestion truncates itself rather than the record.
  """
  @spec merge([String.t()], [String.t()]) :: {[String.t()], [String.t()]}
  def merge(existing, suggested) do
    existing = existing || []
    # Compared in the SAME normal form the suggestions are normalised into, or an existing
    # `RLS` fails to match a suggested `rls` and the article ends up carrying both — two
    # lexemes for one idea, which is the fragmentation this exists to reduce.
    known = MapSet.new(existing, &normalize/1)

    added =
      suggested
      |> Enum.map(&normalize/1)
      |> Enum.filter(&valid?/1)
      # A suggestion must never mint a provenance-shaped tag (those identify WHERE an
      # article came from, so a generated one would be a false claim about its source) nor a
      # STRUCTURAL one (`pdf`, `document`): filtering the vocabulary makes those unlikely,
      # this makes them impossible. `topical?/1` is the single predicate both consumers use.
      |> Enum.reject(&(MapSet.member?(known, &1) or not ProvenanceTags.topical?(&1)))
      |> Enum.uniq()
      |> Enum.take(max(Article.max_tags() - length(existing), 0))

    {existing ++ added, added}
  end

  @doc "The implementation module for this call."
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(
      opts,
      :tagger_impl,
      Application.get_env(:loopctl, :knowledge_tagger, __MODULE__.Llm)
    )
  end

  defp normalize(tag) when is_binary(tag), do: tag |> String.trim() |> String.downcase()
  defp normalize(_tag), do: ""

  defp valid?(tag),
    do: tag != "" and String.length(tag) <= @max_tag_length and Regex.match?(@tag_pattern, tag)
end
