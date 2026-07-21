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
  @type credential :: :anthropic | :embedding | :chat

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

  def for_credential(:chat) do
    %{
      action: "configure_llm",
      missing: ["chat_base_url", "chat_api_key"],
      credential: "openai_compatible_chat",
      mcp_tool: @mcp_tool,
      example:
        ~s|set_llm_config({"chat_provider": "openai_compatible", "chat_base_url": | <>
          ~s|"https://llm.example.internal/v1", "chat_api_key": "<key for THAT host>", | <>
          ~s|"extraction_model": "<a model that host serves>"})|,
      api: @api,
      docs: @docs_url,
      message:
        "The chat surface (extraction / classification / merge / memory promotion) " <>
          "can run against your OWN OpenAI-compatible endpoint so document text never " <>
          "leaves your boundary. The endpoint is probed with a trivial completion " <>
          "BEFORE it is saved, and changing it requires a matching chat_api_key in the " <>
          "same request (or acknowledge_key_transmission: true to reuse the stored " <>
          "one). Your key is stored encrypted and never returned. Role: user."
    }
  end

  @doc """
  Like `for_credential/1` but narrowing `missing` to the specific field(s) the
  caller determined are absent (US-41.3). An empty list keeps the default.
  """
  @spec for_credential(credential(), [String.t()]) :: map()
  def for_credential(credential, []), do: for_credential(credential)

  def for_credential(credential, missing) when is_list(missing),
    do: credential |> for_credential() |> Map.put(:missing, missing)

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

  # US-41.4 (AC-41.4.6): a fail-CLOSED egress refusal IS agent-actionable, but the
  # action is a POSTURE change, not a credential. Point the agent at the read tool
  # it can call with the key it already has (`egress_posture`, role :agent) and name
  # the three legitimate resolutions. A tenant declaration is deliberately labelled
  # as an unverified attestation here too — the wording is a contract, not prose.
  def for_fallback_reason("egress_blocked") do
    %{
      title: "Egress blocked by a local_only marking",
      detail:
        "This scope is marked local_only and the resolved endpoint is not classified " <>
          "local, so the call was refused before any request was made and no data left " <>
          "the boundary. Call the egress_posture tool (role :agent) to see the resolved " <>
          "endpoints and their locality verdicts. Resolve it by declaring the endpoint " <>
          "as a tenant-trusted endpoint for the required purpose (role :user; a " <>
          "declaration is " <>
          Loopctl.Egress.tenant_declared_label() <>
          "), configuring a local endpoint AT TENANT level (role :user), or clearing " <>
          "the local_only marking (role :user).",
      action: "egress_posture"
    }
  end

  def for_fallback_reason("pin_stale") do
    %{
      title: "Pinned endpoint address changed",
      detail:
        "The declared endpoint's address set changed (a new DHCP lease, a moved " <>
          "tailscale funnel). This is NOT an egress policy refusal. Re-pin the endpoint " <>
          "via the egress repin operation — it requires NO role :user write — and retry.",
      action: "egress_repin"
    }
  end

  def for_fallback_reason(_other), do: nil
end
