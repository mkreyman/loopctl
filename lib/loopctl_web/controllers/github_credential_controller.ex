defmodule LoopctlWeb.GitHubCredentialController do
  @moduledoc """
  The tenant's own GitHub token (#936), which every forge call made for the tenant
  authenticates with (`Loopctl.Forge`, `Loopctl.Verification.Credential`).

  - `GET    /api/v1/tenants/me/github-credential` — whether a token is set, its last-4 hint,
    and the repositories the operator's token is lent for. NEVER returns the token.
  - `PUT    /api/v1/tenants/me/github-credential` — set or replace the token.
  - `DELETE /api/v1/tenants/me/github-credential` — remove it; forge calls fall back to what
    the operator lent the tenant, by default nothing.

  All three are `:user`: the endpoint manages a stored credential (security checklist §2), the
  same line `LlmConfigController` holds. Setting and clearing are also human-anchored, part of
  the `issue_intake` surface (`Loopctl.Tenants.TierCapabilities`): the token serves the
  delivery loop's custody surfaces, which an agent-rooted tenant cannot use.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Forge
  alias Loopctl.Verification.OperatorCredential

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user
  # The token authenticates the delivery loop's forge calls, a custody surface an agent-rooted
  # tenant cannot use; setting one is part of the human-anchored intake surface.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:update, :delete]

  tags(["GitHub Credential"])

  @common_errors %{
    401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
    403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
    429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
  }

  operation(:show,
    summary: "Get the tenant's GitHub credential",
    description:
      "Whether the tenant has set its own GitHub token (`has_token`), a masked last-4 hint, " <>
        "and the repositories the operator's token is lent for while it has none. The token " <>
        "itself is never returned. Role: user+.",
    responses:
      Map.put(
        @common_errors,
        200,
        {"GitHub credential", "application/json", Schemas.GitHubCredentialResponse}
      )
  )

  operation(:update,
    summary: "Set the tenant's GitHub token",
    description:
      "Stores the tenant's own GitHub token, encrypted, and uses it for EVERY forge call made " <>
        "for the tenant from then on: the merge gate, story and post-deploy verification, " <>
        "thread checkpoint reads and issue closing. It replaces the operator's token for " <>
        "every repository, including pairs `VERIFICATION_OPERATOR_TOKEN_TENANTS` names. It " <>
        "needs read access to contents, pull requests, actions and commit statuses on the " <>
        "tenant's intake-source repositories, and issues: write for issue closing. The token " <>
        "is not checked against GitHub here: a token that cannot read a repository shows up " <>
        "as that repository's forge refusal. 422 when blank, over 500 characters or " <>
        "containing whitespace. 403 custody_tier_required on an agent-rooted tenant. Role: user+.",
    request_body: {"Token", "application/json", Schemas.GitHubCredentialRequest},
    responses:
      @common_errors
      |> Map.put(200, {"Credential", "application/json", Schemas.GitHubCredentialResponse})
      |> Map.put(422, {"Validation error", "application/json", Schemas.ErrorResponse})
  )

  operation(:delete,
    summary: "Remove the tenant's GitHub token",
    description:
      "Deletes the stored token. Forge calls for the tenant then use the operator's token " <>
        "only for pairs `VERIFICATION_OPERATOR_TOKEN_TENANTS` names, and are refused " <>
        "`credential_unavailable` for every other repository. Idempotent. Role: user+.",
    responses:
      Map.put(
        @common_errors,
        200,
        {"Credential", "application/json", Schemas.GitHubCredentialResponse}
      )
  )

  @doc "GET /api/v1/tenants/me/github-credential"
  def show(conn, _params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    json(conn, respond(tenant_id, Forge.view(tenant_id)))
  end

  @doc "PUT /api/v1/tenants/me/github-credential"
  def update(conn, params) do
    api_key = conn.assigns.current_api_key

    with {:ok, view} <- Forge.set_token(api_key.tenant_id, Map.get(params, "token"), api_key.id) do
      json(conn, respond(api_key.tenant_id, view))
    end
  end

  @doc "DELETE /api/v1/tenants/me/github-credential"
  def delete(conn, _params) do
    api_key = conn.assigns.current_api_key
    {:ok, view} = Forge.clear_token(api_key.tenant_id, api_key.id)
    json(conn, respond(api_key.tenant_id, view))
  end

  defp respond(tenant_id, view) do
    tenant = String.downcase(tenant_id)

    lent =
      for {^tenant, repo} <- OperatorCredential.allowlist(), do: repo

    Map.put(view, :operator_repositories, lent)
  end
end
