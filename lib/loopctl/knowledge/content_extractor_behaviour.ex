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

  - `scope` -- the `Loopctl.Egress.Scope` the extraction call is made on behalf of
    (US-41.4, AC-41.4.2); a bare `tenant_id` binary is shorthand for the
    TENANT-WIDE scope. Key + model resolution stays tenant-scoped — the project
    half narrows only the `local_only` marking, which is applied at the egress
    chokepoint. CALLERS THAT KNOW THE PROJECT MUST PASS THE SCOPE: content is
    POSTed to the provider from here, so a project-only marking that stops at the
    caller is not enforced at all.
  - `content` -- raw text content to extract knowledge from
  - `opts` -- keyword list of options:
    - `:source_type` -- the coarse kind of source (e.g. `"newsletter"`)
    - `:source_ref` -- the SPECIFIC source: a URL, repo, or document name. Optional,
      but pass it whenever it is known. The extractor mints every article title, and a
      title is only self-qualifying if the extractor knows what it is reading — without
      this it can only title a CHANGELOG file "Changelog", which is what generated the
      filename-title collision class on the hosted corpus (#617). Omit it rather than
      passing a placeholder: a model will qualify a title WITH the word "unknown". This
      value LEAVES for the provider inside the prompt, so a caller passing a fetch URL
      strips userinfo and query string first (see `Loopctl.Workers.ContentIngestionWorker`)
      — that is where presigned signatures and share tokens live.

  ## Returns

  - `{:ok, articles}` -- list of article attribute maps
  - `{:error, :no_api_key}` -- the tenant has no Anthropic key configured
    (mandatory BYO); the caller must fail cleanly (422 / `{:discard}`)
  - `{:error, reason}` -- extraction failure (triggers Oban retry)
  """
  @callback extract_from_content(
              scope :: Loopctl.Egress.Scope.t() | Ecto.UUID.t(),
              content :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, [article_attrs()]} | {:error, :no_api_key} | {:error, term()}
end
