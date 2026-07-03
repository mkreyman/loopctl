defmodule LoopctlWeb.LlmConfigController do
  @moduledoc """
  Per-tenant BYO Anthropic LLM configuration (Epic 28 residual, #179).

  - `GET   /api/v1/tenants/me/llm-config` — the tenant's model choices +
    `has_api_key` + a masked last-4 hint. NEVER returns the key itself.
  - `PATCH /api/v1/tenants/me/llm-config` — set/rotate the api_key and the three
    per-operation models (partial-merge; omitted fields are left untouched).

  Both endpoints require the `:user` role — this endpoint stores a tenant secret,
  so per the security checklist (managing secrets ⇒ `:user`) neither agents nor
  orchestrators may read or write it.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Llm

  action_fallback LoopctlWeb.FallbackController

  # Managing a stored secret is a user-level operation (security checklist §2).
  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["LLM Configuration"])

  operation(:show,
    summary: "Get the tenant's LLM configuration",
    description:
      "Returns the per-operation model choices, whether an Anthropic API key is " <>
        "configured (`has_api_key`), and a masked last-4 hint. The key itself is " <>
        "never returned. Role: user+.",
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
      "Sets/rotates the tenant's OWN Anthropic API key (stored encrypted, never " <>
        "returned) and the three per-operation models. loopctl fronts no LLM cost " <>
        "— the tenant's key bills the tenant. Role: user+.",
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

    with {:ok, settings} <- Llm.upsert_settings(tenant_id, config_params(params)) do
      json(conn, Llm.settings_view(settings))
    end
  end

  # Whitelist the accepted keys so nothing else (e.g. tenant_id) can slip in.
  defp config_params(params) do
    Map.take(params, ["api_key", "extraction_model", "classification_model", "merge_model"])
  end
end
