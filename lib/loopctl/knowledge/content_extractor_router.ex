defmodule Loopctl.Knowledge.ContentExtractorRouter do
  @moduledoc """
  Tenant-aware router for `Loopctl.Knowledge.ContentExtractorBehaviour`
  (US-41.3, AC-41.3.2).

  ## The DI seam is PRESERVED, not replaced

  `config :loopctl, :content_extractor, ...` still names ONE module, resolved at
  call time via `Application.get_env` exactly as CLAUDE.md's config-based DI
  requires. That module is now THIS router, which dispatches per call to the
  Anthropic or the OpenAI-compatible sibling based on the TENANT's settings.
  Consequences that matter:

    * `config/test.exs`'s Mox mapping is UNTOUCHED — the seam still points at
      `Loopctl.MockContentExtractor` in tests, so no existing test changes and no
      test needs `Application.put_env` (which CLAUDE.md forbids).
    * No dependency is passed as a function opt. Opts remain query parameters.

  ## Why NOT `Application.compile_env`

  A deliberate, documented departure from the compile-time half of the DI
  convention (the one Oban workers use): provider choice is TENANT DATA, not
  deployment config. Two tenants on ONE node may use different providers, so the
  decision cannot be frozen at compile time — `sibling_for/1` reads the tenant's
  settings (ETS read-through cached) on every call.

  ## No grand provider abstraction

  There is deliberately no `Provider` behaviour over Anthropic + OpenAI. The
  task-level behaviours are the existing, tested seam; a router plus a sibling per
  behaviour keeps the blast radius small.
  """

  @behaviour Loopctl.Knowledge.ContentExtractorBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.ClaudeContentExtractor
  alias Loopctl.Knowledge.OpenAiContentExtractor
  alias Loopctl.Llm

  @doc """
  The sibling impl this tenant's calls dispatch to.

  Public so the tenant-scoped selection is directly assertable (TC-41.3.1) and so
  an operator can answer "which provider is tenant X on?" from one call.
  """
  @spec sibling_for(Ecto.UUID.t()) :: module()
  def sibling_for(tenant_id) when is_binary(tenant_id) do
    case Llm.chat_provider(tenant_id) do
      :openai_compatible -> OpenAiContentExtractor
      :anthropic -> ClaudeContentExtractor
    end
  end

  @impl true
  def extract_from_content(scope_or_tenant_id, content, opts \\ []) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    sibling_for(scope.tenant_id).extract_from_content(scope, content, opts)
  end
end
