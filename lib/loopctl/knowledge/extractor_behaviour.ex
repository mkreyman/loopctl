defmodule Loopctl.Knowledge.ExtractorBehaviour do
  @moduledoc """
  Behaviour for extracting knowledge articles from review findings.

  Implementations receive a context map containing review details
  (story, review type, findings, summary) and return a list of
  article attribute maps suitable for `Article.create_changeset/2`.

  The default production implementation (`LlmExtractor`) calls the Anthropic
  Messages API using the TENANT's own BYO key (Epic 28, #179) and records token
  usage — there is no global-system-key fallback.
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
  Extracts knowledge article attribute maps from review context, using the
  tenant's BYO Anthropic key + extraction model.

  Returns `{:ok, articles}` with a list of article attribute maps,
  `{:error, :no_api_key}` when the tenant has no key configured (mandatory BYO),
  or `{:error, reason}` on other failures (triggers Oban retry).

  The first argument is the `Loopctl.Egress.Scope` the call is made on behalf of
  (US-41.4, AC-41.4.2) — the reviewed STORY's project, since the review context is
  POSTed to the provider. A bare `tenant_id` binary is shorthand for the
  tenant-wide scope.
  """
  @callback extract_articles(scope :: Loopctl.Egress.Scope.t() | Ecto.UUID.t(), context()) ::
              {:ok, [article_attrs()]} | {:error, :no_api_key} | {:error, term()}
end
