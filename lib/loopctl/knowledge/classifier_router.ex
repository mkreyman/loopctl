defmodule Loopctl.Knowledge.ClassifierRouter do
  @moduledoc """
  Tenant-aware router for `Loopctl.Knowledge.ClassifierBehaviour` (US-41.3,
  AC-41.3.2).

  The module named by `config :loopctl, :category_classifier, ...` stays the
  SINGLE resolution point; it is now this router, dispatching per call to the
  Anthropic or OpenAI-compatible sibling based on TENANT settings.
  `config/test.exs`'s Mox mapping is untouched.

  ## The pre-resolved-credential batch path

  `Loopctl.Workers.KnowledgeReclassifyWorker` resolves credentials ONCE and passes
  `opts[:api_key]` / `opts[:model]` / `opts[:provider]` to save a per-article
  resolve. Those credentials belong to whichever provider the BATCH resolved — and
  the batch resolve and this router's per-call provider resolve are two SEPARATE
  reads that can disagree (a mid-batch provider flip, a cluster invalidation or a
  TTL refresh landing between them).

  The router therefore resolves the PROVIDER FIRST and forwards the pre-resolved
  credentials ONLY when the caller tagged them with that same provider; otherwise
  it STRIPS `:api_key`/`:model` and the sibling resolves its own. Defence is
  layered on both sides: `Loopctl.Knowledge.ClaudeCategoryClassifier` accepts
  pre-resolved credentials only when tagged `provider: :anthropic`, and the
  OpenAI-compatible sibling IGNORES pre-resolved opts credentials entirely. So an
  Anthropic key can never reach a tenant-supplied host, and a tenant's local key
  can never reach api.anthropic.com, even if a future caller forwards one.

  Provider choice is tenant DATA, not deployment config — see
  `Loopctl.Knowledge.ContentExtractorRouter` for the full rationale.
  """

  @behaviour Loopctl.Knowledge.ClassifierBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeCategoryClassifier
  alias Loopctl.Knowledge.OpenAiCategoryClassifier
  alias Loopctl.Llm

  @doc "The sibling impl this tenant's calls dispatch to (TC-41.3.1)."
  @spec sibling_for(Ecto.UUID.t()) :: module()
  def sibling_for(tenant_id) when is_binary(tenant_id),
    do: tenant_id |> Llm.chat_provider() |> sibling_for_provider()

  @impl true
  def classify(scope_or_tenant_id, title, body, opts \\ []) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    provider = Llm.chat_provider(scope.tenant_id)

    sibling_for_provider(provider).classify(
      scope,
      title,
      body,
      scoped_credentials(opts, provider)
    )
  end

  # Pre-resolved credentials survive ONLY when they are tagged with the provider
  # this call is actually dispatching to. The batch caller resolved once, per KICK;
  # the provider is resolved here, per ARTICLE, from a second (independently
  # cached) settings read — so the two CAN disagree when a tenant flips provider
  # mid-batch or an invalidation/TTL refresh lands between them. Stripping the
  # credentials on disagreement costs one extra resolve for the affected articles
  # and makes the leak structurally impossible rather than conventionally avoided.
  # An UNTAGGED caller is treated as a mismatch for the same reason.
  defp scoped_credentials(opts, provider) do
    if Keyword.get(opts, :provider) == provider do
      opts
    else
      Keyword.drop(opts, [:api_key, :model, :provider])
    end
  end

  defp sibling_for_provider(:openai_compatible), do: OpenAiCategoryClassifier
  defp sibling_for_provider(:anthropic), do: ClaudeCategoryClassifier
end
