defmodule LoopctlWeb.IntakeSourceController do
  @moduledoc """
  Create, list and revoke the GitHub intake sources of the agent delivery loop (issue #803).

  All actions require `user` role, and the writes require a human-anchored tenant
  (`RequireHumanAnchor`, surface `:issue_intake`): an intake source admits outside text into
  the work queue of a project whose stories an implementer will act on, so an agent-rooted
  tenant may not open one for itself.

  Creating a source MINTS a credential — the webhook secret, which belongs to no dispatch
  lineage — so it carries the same lineage ceiling as `POST /api/v1/api_keys`: a caller whose
  own key a dispatch minted is refused with `403 api_key_mint_forbidden`
  (`LoopctlWeb.Plugs.RequireUnlineagedCaller`).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :update, :delete]
  plug LoopctlWeb.Plugs.RequireUnlineagedCaller when action in [:create]

  tags(["Intake"])

  @source_schema %Schema{
    type: :object,
    required: [:id, :project_id, :repo_full_name, :target_epic_id, :revoked_at, :inserted_at],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      project_id: %Schema{type: :string, format: :uuid},
      target_epic_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description:
          "The epic a story triaged from this source's issues is created in. NULL means " <>
            "the question has not been answered, and a report arriving on such a source is " <>
            "ESCALATED to a human rather than landing in an epic chosen for it."
      },
      repo_full_name: %Schema{type: :string, pattern: Source.repo_format().source},
      revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  }

  operation(:create,
    summary: "Create a GitHub intake source",
    description:
      "Binds one GitHub repository to one ACTIVE WORK project and returns its webhook secret " <>
        "ONCE, as `webhook_secret`, with the path to configure as the webhook URL, " <>
        "`webhook_path`. Configure the repository webhook with that URL on this host, " <>
        "content type `application/json`, the secret, and the `Issues` event. Issue text " <>
        "arriving there is stored only as untrusted data and never becomes a story. Requires " <>
        "user role and a human-anchored tenant; a caller whose key was minted by a dispatch " <>
        "is refused with 403 `api_key_mint_forbidden`. 422 when the repository is not " <>
        "`owner/name`, an active source already binds it, or the project is missing, not a " <>
        "work project, or archived, or `target_epic_id` names an epic that is not in that " <>
        "project. The secret is encrypted at rest.",
    request_body:
      {"Intake source", "application/json",
       %Schema{
         type: :object,
         required: [:repo_full_name, :project_id],
         properties: %{
           repo_full_name: %Schema{
             type: :string,
             pattern: Source.repo_format().source,
             description: "The repository, e.g. `mkreyman/home_care_billing`."
           },
           project_id: %Schema{type: :string, format: :uuid},
           target_epic_id: %Schema{
             type: :string,
             format: :uuid,
             description:
               "Optional. The epic a story triaged from this source's issues is created " <>
                 "in; it must belong to this source's project. Omit it and reports from " <>
                 "this source are escalated to a human instead of becoming stories, which " <>
                 "is the safe default rather than a guess."
           }
         }
       }},
    responses: %{
      201 =>
        {"Intake source created", "application/json",
         %Schema{
           type: :object,
           required: [:source, :webhook_secret, :webhook_path],
           properties: %{
             source: @source_schema,
             webhook_secret: %Schema{type: :string, description: "The HMAC secret. Shown once."},
             webhook_path: %Schema{type: :string, description: "/api/v1/intake/github/<id>"}
           }
         }},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List GitHub intake sources",
    description:
      "Lists the tenant's intake sources. The secret is never returned here. Pass " <>
        "`include_revoked=true` for revoked sources too.",
    parameters: [
      include_revoked: [in: :query, type: :boolean, description: "Include revoked sources"]
    ],
    responses: %{
      200 =>
        {"Intake sources", "application/json",
         %Schema{
           type: :object,
           properties: %{sources: %Schema{type: :array, items: @source_schema}}
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Revoke a GitHub intake source",
    description:
      "Revokes the source. Every later delivery to its webhook URL is refused with 401 " <>
        "`invalid_signature`, exactly like a wrong secret. Records already received are kept. " <>
        "Idempotent. Requires user role and a human-anchored tenant.",
    parameters: [id: [in: :path, type: :string, description: "Intake source UUID"]],
    responses: %{
      200 =>
        {"Intake source revoked", "application/json",
         %Schema{type: :object, properties: %{source: @source_schema}}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Repoint a GitHub intake source at an epic",
    description:
      "Sets `target_epic_id` on an ACTIVE source, or clears it with an explicit null. The " <>
        "epic must belong to this source\'s project. This is the remedy for a source enrolled " <>
        "before the field existed, or one whose reports are being retried because it names no " <>
        "epic: until it does, every record from it stays `pending_triage` and is retried, and " <>
        "the moment it does they promote on the next run with nothing lost. Revoked sources " <>
        "are 404 — revoking CLEARS the target so the epic can be deleted, and repointing one " <>
        "would restore that block on a source that will never report again. Requires user " <>
        "role and a human-anchored tenant. 422 when the epic is not in the project.",
    parameters: [id: [in: :path, type: :string, description: "Intake source UUID"]],
    request_body:
      {"Repoint", "application/json",
       %Schema{
         type: :object,
         required: [:target_epic_id],
         properties: %{
           target_epic_id: %Schema{
             type: :string,
             format: :uuid,
             nullable: true,
             description:
               "The epic triaged stories land in; it must belong to this source\'s project. " <>
                 "Null clears it, which returns the source to escalating nothing and " <>
                 "retrying every report."
           }
         }
       }},
    responses: %{
      200 =>
        {"Intake source updated", "application/json",
         %Schema{type: :object, properties: %{source: @source_schema}}},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/intake/sources"
  def create(conn, params) do
    tenant = conn.assigns.current_tenant

    # `target_epic_id` is OPTIONAL and is passed through as given, including absent: the
    # context distinguishes "not answered" (nil, and reports escalate) from "answered wrongly"
    # (an epic outside this source's project, refused at enrollment). Dropping it here is what
    # made the column unreachable through every documented path — the only way to set it was
    # direct SQL, so every promote escalated and the feature had no code path at all.
    attrs = %{
      repo_full_name: params["repo_full_name"],
      project_id: params["project_id"],
      target_epic_id: params["target_epic_id"]
    }

    with {:ok, %{source: source, webhook_secret: secret}} <-
           Intake.create_source(tenant.id, attrs, actor_lineage: actor_lineage(conn)) do
      conn
      |> put_status(:created)
      |> json(%{
        source: source,
        webhook_secret: secret,
        webhook_path: "/api/v1/intake/github/#{source.id}"
      })
    end
  end

  @doc "PATCH /api/v1/intake/sources/:id"
  def update(conn, %{"id" => source_id} = params) do
    tenant = conn.assigns.current_tenant

    # `Map.get`, so an absent key and an explicit null are the SAME here — both nil — and that
    # is deliberate: the body has exactly one field, so a PATCH that names nothing is a
    # request to clear it rather than a no-op worth distinguishing. `target_epic_id` is
    # `required` in the request schema, which is what makes "absent" an OpenAPI error rather
    # than a silent clear for anyone reading the spec.
    with {:ok, source} <-
           Intake.repoint_source(tenant.id, source_id, Map.get(params, "target_epic_id"),
             actor_lineage: actor_lineage(conn)
           ) do
      json(conn, %{source: source})
    end
  end

  @doc "GET /api/v1/intake/sources"
  def index(conn, params) do
    tenant = conn.assigns.current_tenant
    include_revoked = params["include_revoked"] == "true"

    json(conn, %{sources: Intake.list_sources(tenant.id, include_revoked: include_revoked)})
  end

  @doc "DELETE /api/v1/intake/sources/:id"
  def delete(conn, %{"id" => source_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, source} <-
           Intake.revoke_source(tenant.id, source_id, actor_lineage: actor_lineage(conn)) do
      json(conn, %{source: source})
    end
  end

  defp actor_lineage(conn) do
    api_key = conn.assigns.current_api_key
    Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
  end
end
