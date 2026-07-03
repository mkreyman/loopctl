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

  - `tenant_id` -- the tenant whose BYO Anthropic key + extraction model to use.
    The implementation resolves the tenant's key via `Loopctl.Llm.resolve/2` and
    records token usage after a successful call.
  - `content` -- raw text content to extract knowledge from
  - `opts` -- keyword list of options (e.g., `source_type: "newsletter"`)

  ## Returns

  - `{:ok, articles}` -- list of article attribute maps
  - `{:error, :no_api_key}` -- the tenant has no Anthropic key configured
    (mandatory BYO); the caller must fail cleanly (422 / `{:discard}`)
  - `{:error, reason}` -- extraction failure (triggers Oban retry)
  """
  @callback extract_from_content(
              tenant_id :: Ecto.UUID.t(),
              content :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, [article_attrs()]} | {:error, :no_api_key} | {:error, term()}
end
