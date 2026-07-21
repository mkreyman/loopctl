defmodule LoopctlWeb.LlmConfigController do
  @moduledoc """
  Per-tenant BYO Anthropic LLM + embedding configuration (Epic 28 residual, #179).

  - `GET   /api/v1/tenants/me/llm-config` — the tenant's model choices +
    `has_api_key` / `has_embedding_key` + masked last-4 hints. NEVER returns a key.
  - `PATCH /api/v1/tenants/me/llm-config` — set/rotate the Anthropic `api_key`, the
    OpenAI `embedding_api_key`, and the per-operation models (partial-merge;
    omitted fields are left untouched).

  Both endpoints require the `:user` role — this endpoint stores tenant secrets,
  so per the security checklist (managing secrets ⇒ `:user`) neither agents nor
  orchestrators may read or write it.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Llm
  alias Loopctl.Llm.ChatProbe

  action_fallback LoopctlWeb.FallbackController

  # Managing a stored secret is a user-level operation (security checklist §2).
  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["LLM Configuration"])

  operation(:show,
    summary: "Get the tenant's LLM configuration",
    description:
      "Returns the per-operation model choices, whether an Anthropic API key " <>
        "(`has_api_key`) and an embedding API key (`has_embedding_key`) are " <>
        "configured, plus masked last-4 hints. No key itself is ever returned. " <>
        "Role: user+.",
    responses: %{
      200 => {"LLM config", "application/json", Schemas.LlmConfigResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Set the tenant's LLM configuration",
    description:
      "Sets/rotates the tenant's OWN Anthropic API key + OpenAI embedding key " <>
        "(both stored encrypted, never returned) and the per-operation models. " <>
        "loopctl fronts no cost — the tenant's keys bill the tenant. Role: user+.",
    request_body: {"LLM config", "application/json", Schemas.LlmConfigUpdateRequest},
    responses: %{
      200 => {"Updated LLM config", "application/json", Schemas.LlmConfigResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/tenants/me/llm-config"
  def show(conn, _params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    view = tenant_id |> Llm.get_settings() |> Llm.settings_view()
    json(conn, view)
  end

  @doc "PATCH /api/v1/tenants/me/llm-config"
  def update(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    attrs = config_params(params)

    # US-41.3 (AC-41.3.3): a chat-ENDPOINT change is credential-rule-checked and
    # PROBED with a trivial completion BEFORE anything is persisted. A PATCH that
    # does not touch the chat endpoint short-circuits inside `preflight/2`, so the
    # default Anthropic path is byte-identical to before this story (AC-41.3.7).
    with :ok <- ChatProbe.preflight(tenant_id, attrs),
         {:ok, settings} <- Llm.upsert_settings(tenant_id, upsert_attrs(attrs)) do
      json(conn, Llm.settings_view(settings))
    end
  end

  # Whitelist the accepted keys so nothing else (e.g. tenant_id) can slip in.
  defp config_params(params) do
    Map.take(params, [
      "api_key",
      "extraction_model",
      "classification_model",
      "merge_model",
      "embedding_api_key",
      "embedding_model",
      # US-41.3: the pluggable chat surface.
      "chat_provider",
      "chat_base_url",
      "chat_api_key",
      "acknowledge_key_transmission"
    ])
  end

  # `acknowledge_key_transmission` is a REQUEST-scoped assertion consumed by the
  # probe, never a stored field — drop it before the upsert so it can't reach a
  # changeset.
  defp upsert_attrs(attrs), do: Map.delete(attrs, "acknowledge_key_transmission")
end
