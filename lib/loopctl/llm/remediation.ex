defmodule Loopctl.Llm.Remediation do
  @moduledoc """
  Shared, machine-readable BYO-LLM remediation objects for self-service onboarding.

  loopctl is agent-native and strictly BYO: every tenant provisions its OWN
  provider keys and pays the provider directly (see `Loopctl.Llm`). When a
  knowledge-LLM operation is blocked because a key is missing, the API returns a
  STRUCTURED, ACTIONABLE remediation an agent can act on WITHOUT a human — it
  names the exact MCP tool (`set_llm_config`), the REST endpoint, a copy-paste
  example, and the onboarding docs. This is the linchpin that turns a dead-end
  "no key" wall into a next step a stranger agent can follow from the tool result
  alone.

  Two SEPARATE credentials back two different capabilities, so the remediation
  distinguishes WHICH one is missing:

    * `:anthropic` — the Anthropic `api_key` powers ingest synthesis / classify /
      merge. Missing ⇒ `POST /knowledge/ingest` 422s.
    * `:embedding` — the OpenAI-compatible `embedding_api_key` powers article
      embeddings + semantic search. Missing ⇒ search silently degrades to
      keyword-only (`meta.fallback_reason: "no_embedding_key"`).

  The objects are VALUE-FREE: they never carry a key, a provider body, or any
  tenant secret — only the field NAME the agent must set. Safe to render into any
  API response or MCP tool result.
  """

  # Agent-facing canonical onboarding reference (mirrors the FallbackController
  # `learn_more` wiki-URL convention). The in-repo companion is
  # `docs/onboarding-agent-tenant.md`.
  @docs_url "https://loopctl.com/wiki/agent-onboarding"

  @mcp_tool "set_llm_config"
  @api "PATCH /api/v1/tenants/me/llm-config"

  @typedoc "The credential a blocked operation needs the tenant to provision."
  @type credential :: :anthropic | :embedding

  @typedoc "A machine-readable, secret-free remediation object."
  @type t :: %{
          action: String.t(),
          missing: [String.t()],
          credential: String.t(),
          mcp_tool: String.t(),
          example: String.t(),
          api: String.t(),
          docs: String.t(),
          message: String.t()
        }

  @doc """
  Build the remediation object for a missing `credential`.

    * `:anthropic` → the `api_key` (ingest / classify / merge)
    * `:embedding` → the `embedding_api_key` (embeddings / semantic search)

  The returned map is secret-free and safe to embed in any response or tool result.
  """
  @spec for_credential(credential()) :: t()
  def for_credential(:anthropic) do
    %{
      action: "configure_llm",
      missing: ["api_key"],
      credential: "anthropic_api_key",
      mcp_tool: @mcp_tool,
      example: ~s|set_llm_config({"api_key": "<your Anthropic API key>"})|,
      api: @api,
      docs: @docs_url,
      message:
        "This tenant has no Anthropic API key configured. loopctl is BYO — provision " <>
          "your own key ONCE via the set_llm_config MCP tool (user role), then ingest works. " <>
          "Your key is stored encrypted and never returned."
    }
  end

  def for_credential(:embedding) do
    %{
      action: "configure_llm",
      missing: ["embedding_api_key"],
      credential: "openai_embedding_api_key",
      mcp_tool: @mcp_tool,
      example: ~s|set_llm_config({"embedding_api_key": "<your OpenAI API key>"})|,
      api: @api,
      docs: @docs_url,
      message:
        "Semantic ranking is unavailable because this tenant has no embedding API key " <>
          "configured — search degraded to keyword-only. loopctl is BYO — provision your own " <>
          "OpenAI-compatible key ONCE via the set_llm_config MCP tool (user role) to enable " <>
          "embeddings + semantic search. Your key is stored encrypted and never returned."
    }
  end

  @doc """
  Map a search `fallback_reason` tag (see `Loopctl.Knowledge`) to a remediation,
  or `nil` when the reason is NOT a missing-key condition.

  Only `"no_embedding_key"` is actionable by the agent (provision a key). Every
  other tag (`"embedding_circuit_open"`, `"embedding_timeout"`,
  `"embedding_provider_error_<status>"`, ...) means a key IS configured but the
  provider/circuit failed transiently — telling the agent to "configure a key"
  would be wrong, so those return `nil`.
  """
  @spec for_fallback_reason(String.t() | nil) :: t() | nil
  def for_fallback_reason("no_embedding_key"), do: for_credential(:embedding)
  def for_fallback_reason(_other), do: nil
end
