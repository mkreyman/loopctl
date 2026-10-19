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
  (`LoopctlWeb.Plugs.RequireUnlineagedCaller`). An UPDATE that names `change_events_secret`
  or `chg_root_dispatch_id`, or sets `mode` to `chg` (US-47.2), is held to the same ceiling,
  refused `403 chg_registration_forbidden`: the secret is a credential chg-server's event
  webhook authenticates with, it belongs to no lineage either, and the root is the custody
  input that decides whose reviews a `chg` story accepts. A bare `mode: chg` is included
  because it RE-ACTIVATES whichever secret and root the source kept from an earlier `chg`
  stint — registering them again without naming them.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias LoopctlWeb.Plugs.RequireUnlineagedCaller
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :update, :delete]
  plug LoopctlWeb.Plugs.RequireUnlineagedCaller when action in [:create]

  @chg_ceiling_code "chg_registration_forbidden"

  @chg_ceiling_message "Your key was minted by a dispatch, so it sits inside a lineage. Making " <>
                         "an intake source `chg` (`mode: chg`) or naming its " <>
                         "`change_events_secret` or `chg_root_dispatch_id` registers a " <>
                         "credential and a custody root that belong to no lineage, so only a " <>
                         "principal outside every lineage may do it. Send this request with " <>
                         "the tenant's operator key — a `user`-role key no dispatch minted. " <>
                         "A key minted by a dispatch beneath yours is refused the same way."

  @chg_ceiling_remedy "Retry with the tenant's operator key: a user-role key no dispatch " <>
                        "minted (the MCP intake tools send LOOPCTL_USER_KEY)."

  tags(["Intake"])

  @required_checks_doc "The checks STORY VERIFICATION judges a story's commit by (US-26.4.6): " <>
                         "GitHub Actions JOB names as they appear on the commit. Story " <>
                         "verification first needs a GitHub credential " <>
                         "for the tenant: its own token (`set_github_credential`) or an entry " <>
                         "in `VERIFICATION_OPERATOR_TOKEN_TENANTS` (`credential_unavailable` " <>
                         "otherwise, whatever this list holds); then a `pr` source that names " <>
                         "none records `no_required_checks` and reads nothing — naming them is " <>
                         "how a source opts in — and a source that names some has its " <>
                         "(tenant, repository) credential resolved before any GitHub read " <>
                         "(`credential_unavailable` if there is none). At most " <>
                         "#{Source.max_required_checks()} distinct, non-blank names of at most " <>
                         "#{Source.max_check_name_bytes()} bytes, no surrounding whitespace. Only a " <>
                         "job of a GitHub Actions workflow run that a push of the story's " <>
                         "branch triggered, concluding `success`, satisfies one, so a " <>
                         "check that runs only `on: pull_request` never " <>
                         "satisfies verification. Each required job must run on every push " <>
                         "to the story branches (no path " <>
                         "filter or job-level `if:`): one that never appears leaves the story " <>
                         "unverified. " <>
                         "`local-gate` is refused (422): " <>
                         "that status is posted by whoever pushed, so it can never satisfy a " <>
                         "required check."

  @mode_doc "How this repository's changes reach its base branch. `pr`: the merge gate reads " <>
              "a pull request by number. `chg` (US-47.2): the change protocol lands them " <>
              "(`chg submit`), and the merge precondition refuses every story on the source " <>
              "with 409 `change_protocol_enrolled`. A `chg` source needs BOTH " <>
              "`change_events_secret` and `chg_root_dispatch_id`, from the same request or " <>
              "kept from an earlier `chg` stint; without them the write is a 422. Switching " <>
              "back to `pr` KEEPS both and ignores them, and every write that leaves the " <>
              "source `chg` re-checks the root. A switch to `chg` is 409 " <>
              "`pr_route_in_flight` while a story of the project holds a merge allow it has " <>
              "not merged on. NOT nullable: an explicit null or any other value is a 422."

  @change_events_secret_doc "WRITE-ONLY. The HMAC key chg-server signs its event webhook " <>
                              "with (`POST /api/v1/change_events/:source_id`); chg-server " <>
                              "must hold the same value. It " <>
                              Source.change_events_secret_rule() <>
                              ". Encrypted at rest and NEVER returned by any response, so " <>
                              "keep your own copy. Required when the source is `chg`; on a " <>
                              "`pr` source an explicit null clears it. Not GitHub's " <>
                              "`webhook_secret`, which is never reused."

  @chg_root_doc "The dispatch chg-server's key was minted from (PRD §6): reviews of a `chg` " <>
                  "story are accepted only from its children. " <>
                  Source.chg_root_requirement() <>
                  " Refused with 422 `chg_root_invalid` otherwise, judged whenever a " <>
                  "request names it (on a `pr` source too) and on EVERY write that leaves " <>
                  "the source `chg` — a secret rotation or a base-branch edit on a `chg` " <>
                  "source whose root has since been revoked is the same 422 until a live root " <>
                  "is named. " <>
                  "Required when the source is `chg`; on a `pr` source an explicit null " <>
                  "clears it."

  @source_schema %Schema{
    type: :object,
    required: [
      :id,
      :project_id,
      :repo_full_name,
      :base_branch,
      :mode,
      :required_checks,
      :chg_root_dispatch_id,
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
      required_checks: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: @required_checks_doc
      },
      mode: %Schema{type: :string, enum: ["pr", "chg"], description: @mode_doc},
      chg_root_dispatch_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description:
          "The registered chg-server root dispatch; null unless one was named. " <>
            "`change_events_secret` is never in a response."
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
        "the body does not name it, and `mode` to `pr`. Enrolling in mode `chg` (US-47.2) " <>
        "also needs `change_events_secret` and `chg_root_dispatch_id` (422 naming the " <>
        "missing field otherwise), and a root that is not a parentless, unrevoked, " <>
        "orchestrator-role dispatch of this tenant is 422 `chg_root_invalid`.",
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
           required_checks: %Schema{
             type: :array,
             items: %Schema{
               type: :string,
               minLength: 1,
               maxLength: Source.max_check_name_bytes()
             },
             maxItems: Source.max_required_checks(),
             description: "Optional. " <> @required_checks_doc
           },
           mode: %Schema{
             type: :string,
             enum: ["pr", "chg"],
             description: "Optional, `pr` when omitted. " <> @mode_doc
           },
           change_events_secret: %Schema{
             type: :string,
             writeOnly: true,
             description: "Optional; required with `mode: chg`. " <> @change_events_secret_doc
           },
           chg_root_dispatch_id: %Schema{
             type: :string,
             format: :uuid,
             description: "Optional; required with `mode: chg`. " <> @chg_root_doc
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
             webhook_secret: %Schema{
               type: :string,
               description:
                 "GitHub's HMAC secret. Shown once. (`change_events_secret` is never shown.)"
             },
             webhook_path: %Schema{type: :string, description: "/api/v1/intake/github/<id>"}
           }
         }},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`pr_route_in_flight`, with `story_ids`, for a `chg` enrolment: " <>
           Intake.pr_route_in_flight_message(), "application/json", Schemas.ErrorResponse},
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
        "role and a human-anchored tenant. 422 when the epic is not in the project. " <>
        "`mode`, `change_events_secret` and `chg_root_dispatch_id` (US-47.2): switching to " <>
        "`chg` needs both credentials on the resulting source (422 naming the missing one), " <>
        "and the root is re-checked on every write that leaves the source `chg` (422 " <>
        "`chg_root_invalid`); switching to `pr` keeps them. " <>
        "A body naming `change_events_secret` or `chg_root_dispatch_id`, or setting `mode` " <>
        "to `chg`, from a key a dispatch minted is 403 `#{@chg_ceiling_code}`: " <>
        @chg_ceiling_message <>
        " " <>
        "A switch to `chg` is 409 `pr_route_in_flight` (naming `story_ids`) while a story of " <>
        "the source's project holds a merge allow it has not merged on: " <>
        Intake.pr_route_in_flight_message(),
    parameters: [id: [in: :path, type: :string, description: "Intake source UUID"]],
    request_body:
      {"Repoint", "application/json",
       %Schema{
         type: :object,
         properties: %{
           required_checks: %Schema{
             type: :array,
             items: %Schema{
               type: :string,
               minLength: 1,
               maxLength: Source.max_check_name_bytes()
             },
             maxItems: Source.max_required_checks(),
             description: "Optional. " <> @required_checks_doc
           },
           mode: %Schema{
             type: :string,
             enum: ["pr", "chg"],
             description: "Optional; omitted leaves it as it is. " <> @mode_doc
           },
           change_events_secret: %Schema{
             type: :string,
             nullable: true,
             writeOnly: true,
             description: "Optional; omitted leaves it as it is. " <> @change_events_secret_doc
           },
           chg_root_dispatch_id: %Schema{
             type: :string,
             format: :uuid,
             nullable: true,
             description: "Optional; omitted leaves it as it is. " <> @chg_root_doc
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
                 "handed to git on the runner. It is BOUND to each implement dispatch when " <>
                 "it is placed: a story already placed is merge-gated against the base " <>
                 "branch its dispatch was sent with, and a change reaches only stories " <>
                 "placed afterwards. (`mode` is not bound that way: the merge gate reads the " <>
                 "source's CURRENT mode, so a switch reaches every story at once.)"
           }
         }
       }},
    responses: %{
      200 =>
        {"Intake source updated", "application/json",
         %Schema{type: :object, properties: %{source: @source_schema}}},
      403 =>
        {"Forbidden: insufficient role, `custody_tier_required`, or " <>
           "`#{@chg_ceiling_code}` — " <> @chg_ceiling_message, "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`pr_route_in_flight`, with `story_ids`: " <> Intake.pr_route_in_flight_message(),
         "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "The 403 message a dispatch-minted key gets for a PATCH that registers `chg` credentials."
  @spec chg_ceiling_message() :: String.t()
  def chg_ceiling_message, do: @chg_ceiling_message

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
      |> put_if_present(params, "required_checks", :required_checks)
      |> put_if_present(params, "change_events_secret", :change_events_secret)
      |> put_if_present(params, "chg_root_dispatch_id", :chg_root_dispatch_id)

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
    case guard_chg_credentials(conn, params) do
      %Plug.Conn{halted: true} = refused -> refused
      conn -> do_update(conn, source_id, params)
    end
  end

  # The lineage ceiling `create` carries as a plug, applied here when the body names one of the
  # two `chg` credentials OR sets `mode` to `chg`. The mode is included because a switch back to
  # `chg` re-activates the secret and root the source KEPT from an earlier stint, which registers
  # them exactly as naming them would — so a dispatch-minted key could otherwise restore a root
  # it was never allowed to name. A base-branch repoint or a switch to `pr` registers nothing and
  # stays allowed.
  #
  # Its own code and remedy, not the plug's API-key refusal: "mint a dispatch beneath your own"
  # hands back another lineaged key, which this refuses again.
  defp guard_chg_credentials(conn, params) do
    if Map.has_key?(params, "change_events_secret") or
         Map.has_key?(params, "chg_root_dispatch_id") or params["mode"] == "chg",
       do:
         RequireUnlineagedCaller.call(
           conn,
           code: @chg_ceiling_code,
           message: @chg_ceiling_message,
           remedy: @chg_ceiling_remedy
         ),
       else: conn
  end

  defp do_update(conn, source_id, params) do
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
      |> put_if_present(params, "required_checks", :required_checks)
      |> put_if_present(params, "change_events_secret", :change_events_secret)
      |> put_if_present(params, "chg_root_dispatch_id", :chg_root_dispatch_id)

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
              "Name at least one of target_epic_id (null clears it), base_branch, mode, " <>
                "required_checks, change_events_secret or chg_root_dispatch_id. A field you " <>
                "do not send is left exactly as it was."
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
