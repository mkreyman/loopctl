defmodule Loopctl.Knowledge.ExtractorBehaviour do
  @moduledoc """
  Behaviour for extracting knowledge articles from review findings.

  Implementations receive a context map containing review details
  (story, review type, findings, summary) and return a list of
  article attribute maps suitable for `Article.create_changeset/2`.

  The default production implementation (`LlmExtractor`) is a stub
  that returns an empty list until LLM integration is built.
  """

  @type context :: %{
          required(:review_record_id) => Ecto.UUID.t(),
          required(:tenant_id) => Ecto.UUID.t(),
          required(:story_id) => Ecto.UUID.t(),
          required(:review_type) => String.t(),
          required(:findings_count) => non_neg_integer(),
          required(:fixes_count) => non_neg_integer(),
          required(:summary) => String.t() | nil,
          optional(atom()) => term()
        }

  @type article_attrs :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:category) => atom(),
          optional(:tags) => [String.t()],
          optional(:metadata) => map()
        }

  @doc """
  Extracts knowledge article attribute maps from review context.

  Returns `{:ok, articles}` with a list of article attribute maps,
  or `{:error, reason}` on failure (triggers Oban retry).
  """
  @callback extract_articles(context()) :: {:ok, [article_attrs()]} | {:error, term()}
end
