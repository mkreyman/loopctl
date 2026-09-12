defmodule LoopctlWeb.RunnerController do
  @moduledoc """
  Enroll, list and revoke the runners of the agent delivery loop (issue #801).

  All actions require `user` role, and the writes require a human-anchored tenant
  (`RequireHumanAnchor`, surface `:runner_pool`): a runner executes dispatched sessions
  as its machine's user, so an agent-rooted tenant may not admit one for itself.

  Enrollment MINTS a credential — a plain API key that
  belongs to no dispatch lineage — so it carries the same lineage ceiling as
  `POST /api/v1/api_keys`: a caller whose own key a dispatch minted is refused with
  `403 api_key_mint_forbidden` (`LoopctlWeb.Plugs.RequireUnlineagedCaller`).

  A runner's credential counts toward the tenant's `max_api_keys` limit, because it is
  one.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Auth
  alias Loopctl.Dispatches
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :delete]
  plug LoopctlWeb.Plugs.RequireUnlineagedCaller when action in [:create]

  tags(["Runners"])

  @runner_schema %Schema{
    type: :object,
    required: [:id, :name, :revoked_at, :inserted_at],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string, pattern: Runner.name_format().source},
      revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  }

  operation(:create,
    summary: "Enroll a runner",
    description:
      "Enrolls a dev machine as a runner and returns its credential ONCE, as `token`. The " <>
        "runner presents it in the `x-loopctl-runner-token` header when it connects to " <>
        "`/runner/socket/websocket`, and joins the `runners` topic under exactly this " <>
        "`name`. The wire contract is `priv/runner_contract/v1.json`. Requires user role; " <>
        "a caller whose key was minted by a dispatch is refused with 403 " <>
        "`api_key_mint_forbidden`. 422 when the name is malformed, already used by an " <>
        "active runner, or the tenant is at its API key limit.",
    request_body:
      {"Runner", "application/json",
       %Schema{
         type: :object,
         required: [:name],
         properties: %{
           name: %Schema{
             type: :string,
             pattern: Runner.name_format().source,
             description: "The machine name, e.g. `minis`."
           }
         }
       }},
    responses: %{
      201 =>
        {"Runner enrolled", "application/json",
         %Schema{
           type: :object,
           required: [:runner, :token],
           properties: %{
             runner: @runner_schema,
             token: %Schema{type: :string, description: "The raw credential. Shown once."}
           }
         }},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List runners",
    description:
      "Lists the tenant's enrolled runners. Enrollment only: whether a runner is CONNECTED " <>
        "is Presence, not a row. Pass `include_revoked=true` for revoked ones too.",
    parameters: [
      include_revoked: [in: :query, type: :boolean, description: "Include revoked runners"]
    ],
    responses: %{
      200 =>
        {"Runners", "application/json",
         %Schema{
           type: :object,
           properties: %{runners: %Schema{type: :array, items: @runner_schema}}
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Revoke a runner",
    description:
      "Revokes the runner and its credential in one transaction and disconnects its live " <>
        "socket, which removes it from the pool. Idempotent. Requires user role.",
    parameters: [id: [in: :path, type: :string, description: "Runner UUID"]],
    responses: %{
      200 =>
        {"Runner revoked", "application/json",
         %Schema{type: :object, properties: %{runner: @runner_schema}}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/runners"
  def create(conn, params) do
    tenant = conn.assigns.current_tenant

    with :ok <- validate_key_limit(tenant),
         {:ok, %{runner: runner, raw_key: raw_key}} <-
           Runners.enroll_runner(tenant.id, %{name: params["name"]},
             actor_lineage: actor_lineage(conn)
           ) do
      conn
      |> put_status(:created)
      |> json(%{runner: runner, token: raw_key})
    end
  end

  @doc "GET /api/v1/runners"
  def index(conn, params) do
    tenant = conn.assigns.current_tenant
    include_revoked = params["include_revoked"] == "true"

    json(conn, %{runners: Runners.list_runners(tenant.id, include_revoked: include_revoked)})
  end

  @doc "DELETE /api/v1/runners/:id"
  def delete(conn, %{"id" => runner_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, runner} <-
           Runners.revoke_runner(tenant.id, runner_id, actor_lineage: actor_lineage(conn)) do
      json(conn, %{runner: runner})
    end
  end

  defp validate_key_limit(tenant) do
    max_keys = Tenants.get_tenant_settings(tenant, "max_api_keys", 100)

    if Auth.count_api_keys(tenant.id) >= max_keys do
      {:error, :unprocessable_entity, "API key limit reached (max: #{max_keys})"}
    else
      :ok
    end
  end

  defp actor_lineage(conn) do
    api_key = conn.assigns.current_api_key
    Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
  end
end
