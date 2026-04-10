defmodule Loopctl.Knowledge.ContentExtractorBehaviour do
  @moduledoc """
  Behaviour for extracting knowledge articles from raw content.

  Implementations receive raw text content (web articles, newsletters,
  skill templates, etc.) and return a list of article attribute maps
  suitable for `Article.create_changeset/2`.

  The default production implementation (`ClaudeContentExtractor`) calls
  the Anthropic Messages API. A mock is used in tests.
  """

  @type article_attrs :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:category) => atom(),
          optional(:tags) => [String.t()],
          optional(:metadata) => map()
        }

  @doc """
  Extracts knowledge article attribute maps from raw content.

  ## Parameters

  - `content` -- raw text content to extract knowledge from
  - `opts` -- keyword list of options (e.g., `source_type: "newsletter"`)

  ## Returns

  - `{:ok, articles}` -- list of article attribute maps
  - `{:error, reason}` -- extraction failure (triggers Oban retry)
  """
  @callback extract_from_content(content :: String.t(), opts :: keyword()) ::
              {:ok, [article_attrs()]} | {:error, term()}
end
