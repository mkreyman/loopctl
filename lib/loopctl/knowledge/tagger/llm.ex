defmodule Loopctl.Knowledge.Tagger.Llm do
  @moduledoc """
  Suggests tags for an article while SHOWING the model the vocabulary the corpus already uses.

  That list is the entire mechanism. Tagging an article in isolation is what produced 33,234
  single-use tags out of 60,141 (55.3%) — each capture invents plausible strings for ideas the
  corpus already has words for. The prompt therefore presents the established vocabulary and
  makes reuse the default, with a new tag allowed only when nothing offered fits.

  Per-tenant BYO via `Loopctl.Llm.Anthropic.message/5` under `:classification`, so a tenant
  with no key returns `{:error, :no_api_key}` and the caller leaves the article alone.
  """

  @behaviour Loopctl.Knowledge.Tagger

  alias Loopctl.Llm.Anthropic

  @body_chars 4_000
  @max_tokens 300

  # How many established tags to show. Enough to cover a tenant's real topics; small enough
  # that the vocabulary does not dominate the prompt on every one of thousands of articles.
  @vocabulary_shown 150

  @system_prompt """
  You assign topic tags to a knowledge-base article. You will be given the article and a \
  VOCABULARY of tags this knowledge base already uses.

  Prefer the vocabulary. Reuse an existing tag whenever it fits, even if you would have \
  phrased it differently — a tag that matches what other articles already carry is what makes \
  the collection navigable, and a near-synonym nobody else uses is worse than an imperfect \
  match that many do. Propose a NEW tag only when the article is about something the \
  vocabulary genuinely does not cover.

  Return between 3 and 8 tags describing what the article is ABOUT. Do not tag the format, \
  the source or the file type. Each tag must be lowercase, and may contain only letters, \
  digits, underscores and hyphens — a dot is rejected by the article changeset, so a tag \
  carrying one is dropped.

  Reply with a single compact JSON object with exactly one key, "tags", whose value is an \
  array of strings. Output nothing except that JSON object.\
  """

  @doc "The tagging system prompt. Public so tests and any sibling implementation share it."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "How many established tags the prompt shows."
  @spec vocabulary_shown() :: pos_integer()
  def vocabulary_shown, do: @vocabulary_shown

  @doc "The user message for an article and the corpus vocabulary. Public for testing."
  @spec user_content(map(), [String.t()]) :: String.t()
  def user_content(article, vocabulary) do
    shown = vocabulary |> Enum.take(@vocabulary_shown) |> Enum.join(", ")

    """
    VOCABULARY (prefer these): #{shown}

    ARTICLE
    Title: #{article.title}
    #{String.slice(article.body || "", 0, @body_chars)}
    """
  end

  @impl true
  def suggest(scope_or_tenant_id, article, vocabulary, opts) do
    content = user_content(article, vocabulary)

    body_fun = fn _model ->
      %{
        max_tokens: @max_tokens,
        system: @system_prompt,
        messages: [%{role: "user", content: content}]
      }
    end

    case call(scope_or_tenant_id, opts, body_fun) do
      {:ok, text} -> parse_tags(text)
      {:error, _} = error -> error
    end
  end

  defp call(scope_or_tenant_id, opts, body_fun) do
    case {opts[:tagger_api_key], opts[:tagger_model]} do
      {api_key, model} when is_binary(api_key) and is_binary(model) ->
        Anthropic.call(scope_or_tenant_id, :classification, api_key, model, body_fun)

      _ ->
        Anthropic.message(scope_or_tenant_id, :classification, body_fun)
    end
  end

  @doc """
  Parse a model reply into a tag list.

  Shape only — validity and the provenance-namespace rejection belong to
  `Loopctl.Knowledge.Tagger.merge/2`, which every implementation goes through, so a second
  implementation cannot skip them by parsing leniently.
  """
  @spec parse_tags(String.t() | nil) :: {:ok, [String.t()]} | {:error, atom()}
  def parse_tags(text) when is_binary(text) do
    with {:ok, json} <- extract_json_object(text),
         %{"tags" => tags} when is_list(tags) <- json,
         true <- Enum.all?(tags, &is_binary/1) do
      {:ok, tags}
    else
      _ -> {:error, :unparseable_tags}
    end
  end

  def parse_tags(_text), do: {:error, :unparseable_tags}

  defp extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, String.trim(text)) do
      [json] -> JSON.decode(json)
      _ -> :error
    end
  end
end
