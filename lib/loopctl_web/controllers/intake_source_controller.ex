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
    required: [
      :id,
      :project_id,
      :repo_full_name,
      :base_branch,
      :mode,
      :target_epic_id,
      :revoked_at,
      :inserted_at
    ],
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
      # EVERY RESPONSE CARRIES IT — `Source`'s `@derive {Jason.Encoder, only: [...]}` includes
      # it, so create, index, update and delete all serialise it — and it was missing here, so
      # a client generated from `GET /api/v1/openapi` got a source type without the one field
      # the README and `intake_source_list` tell a caller to check before placing work.
      base_branch: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 255,
        description:
          "The branch every dispatch for this repository is cut FROM. `master` unless the " <>
            "source named or was repointed to another."
      },
      mode: %Schema{
        type: :string,
        enum: ["pr", "thread"],
        description:
          "How this repository's changes reach its base branch. `pr` (the default, and " <>
            "what every source did before the field existed): the merge gate reads a pull " <>
            "request by number. `thread`: the merge gate reads the story's latest RECORDED " <>
            "thread checkpoint and needs no pull request (Epic 45 change threads)."
      },
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
        "project. The secret is encrypted at rest. `base_branch` defaults to `master` when " <>
        "the body does not name it, and `mode` to `pr`.",
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
           mode: %Schema{
             type: :string,
             enum: ["pr", "thread"],
             description:
               "Optional. `pr` (the default when omitted) or `thread`. A `thread` source's " <>
                 "merge gate evaluates the story's latest recorded checkpoint instead of a " <>
                 "pull request, and refuses `branch_head_unrecorded` and `empty_change`. NOT " <>
                 "nullable: an explicit null or any other value is a 422."
           },
           target_epic_id: %Schema{
             type: :string,
             format: :uuid,
             description:
               "Optional. The epic a story triaged from this source's issues is created " <>
                 "in; it must belong to this source's project. Omit it and reports from " <>
                 "this source are escalated to a human instead of becoming stories, which " <>
                 "is the safe default rather than a guess."
           },
           base_branch: %Schema{
             type: :string,
             minLength: 1,
             maxLength: 255,
             description:
               "Optional. The branch every dispatch for this repository is cut FROM, and " <>
                 "the `base_branch` an unattended dispatch carries (#803). OMIT IT for " <>
                 "`master`, which is what dispatches carried before the field existed; send " <>
                 "`main` for a repository created on GitHub since 2020, or the loop places " <>
                 "work against a branch that does not exist. NOT nullable, unlike " <>
                 "`target_epic_id`: there is no unanswered state for a branch a dispatch " <>
                 "must name, so an explicit null or an empty string is a 422 rather than a " <>
                 "silent fallback to the default. It must also be a valid GIT BRANCH NAME " <>
                 "— letters, digits, `.`, `_`, `-` and `/` only, starting with a letter or " <>
                 "digit, no `..` — judged by the same predicate `place_dispatch` applies to " <>
                 "a ref field, because this value is handed to git on the runner. Changed " <>
                 "afterwards with PATCH."
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
      "Sets `target_epic_id` on an ACTIVE source, or clears it with an explicit null, and/or " <>
        "`base_branch`, and/or `mode`. EVERY FIELD IS OPTIONAL AND ONE YOU DO NOT SEND IS " <>
        "LEFT ALONE — clearing the epic takes an explicit null, and a body naming none of " <>
        "them is a 422 `nothing_to_update`. " <>
        "The " <>
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
         properties: %{
           mode: %Schema{
             type: :string,
             enum: ["pr", "thread"],
             description:
               "Optional; omitted leaves it as it is. `pr` or `thread`. A `thread` source's " <>
                 "merge gate evaluates the story's latest recorded checkpoint instead of a " <>
                 "pull request, and refuses `branch_head_unrecorded` and `empty_change`. NOT " <>
                 "nullable: an explicit null or any other value is a 422."
           },
           target_epic_id: %Schema{
             type: :string,
             format: :uuid,
             nullable: true,
             description:
               "The epic triaged stories land in; it must belong to this source\'s project. " <>
                 "Null clears it, which returns the source to escalating nothing and " <>
                 "retrying every report."
           },
           base_branch: %Schema{
             type: :string,
             minLength: 1,
             maxLength: 255,
             description:
               "The branch every dispatch for this repository is cut FROM, and the " <>
                 "`base_branch` an unattended dispatch carries (#803). Defaults to " <>
                 "`master`, which is what dispatches carried before the field existed; set " <>
                 "it to `main` for a repository created on GitHub since 2020, or the loop " <>
                 "places work against a branch that does not exist. OPTIONAL and NOT " <>
                 "nullable, unlike `target_epic_id`: omitting it leaves the current value " <>
                 "(there is no unanswered state for a branch a dispatch must name), and an " <>
                 "explicit null is a 422. It must be a valid GIT BRANCH NAME, judged by the " <>
                 "same predicate as at enrolment and on `place_dispatch`: this value is " <>
                 "handed to git on the runner."
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
    # `base_branch` is read by PRESENCE, the way `update/2` reads both of its fields, and NOT
    # passed through as given like `target_epic_id`. The column is NOT NULL with a default of
    # `master`, so absent and explicitly null are different requests: absent keeps the default
    # every enrolment has always taken, while a caller that named the field gets its value
    # validated. Passing the key unconditionally would turn every enrolment that omits it into
    # a `can't be blank` 422.
    attrs =
      %{
        repo_full_name: params["repo_full_name"],
        project_id: params["project_id"],
        target_epic_id: params["target_epic_id"]
      }
      |> put_if_present(params, "base_branch", :base_branch)
      |> put_if_present(params, "mode", :mode)

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

    # PRESENCE, for both fields. A PATCH is partial by definition, and this action now carries
    # two fields, so "absent means clear" — which the epic alone could just about justify —
    # became a trap the moment a caller could legitimately send only the other one: setting
    # the base branch would have silently UN-POINTED the source from its epic, which by this
    # action's own description strands every record from it at `pending_triage`. The `required`
    # marker in the request schema is documentation, not enforcement: this router mounts no
    # `CastAndValidate`, so nothing refused the body that did it.
    #
    # An explicit null still clears the epic. That is the difference a map can carry and two
    # positional arguments cannot, and it is why the whole update goes to `Intake` as one.
    attrs =
      %{}
      |> put_if_present(params, "target_epic_id", :target_epic_id)
      |> put_if_present(params, "base_branch", :base_branch)
      |> put_if_present(params, "mode", :mode)

    case Intake.update_source(tenant.id, source_id, attrs, actor_lineage: actor_lineage(conn)) do
      {:ok, source} ->
        json(conn, %{source: source})

      # RENDERED HERE, because `FallbackController`'s catch-all answers 500 for an atom it has
      # no clause for — correctly, since an unmapped refusal is a gap. A body naming neither
      # field is a caller error and says so.
      {:error, :nothing_to_update} ->
        conn
        |> put_status(422)
        |> json(%{
          error: %{
            status: 422,
            code: "nothing_to_update",
            message:
              "Name at least one of target_epic_id (null clears it), base_branch or mode. A " <>
                "field you do not send is left exactly as it was."
          }
        })

      {:error, reason} ->
        LoopctlWeb.FallbackController.call(conn, {:error, reason})
    end
  end

  defp put_if_present(attrs, params, key, field) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, field, value)
      :error -> attrs
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
