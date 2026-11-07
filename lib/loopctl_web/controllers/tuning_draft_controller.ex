defmodule LoopctlWeb.TuningDraftController do
  @moduledoc """
  The improvement loop's operator surface (Epic 48, US-48.13):

  - `GET /api/v1/tuning_drafts` — the drafts `spec_tuner@1` stored, newest first,
    keyset-paginated, filterable by project, target spec and status;
  - `POST /api/v1/tuning_drafts/:id/landed` — records that a person merged a `proposed`
    draft's template change, naming the pull request.

  ## Why `role: :user` on both

  A draft's traces are distilled from the stories its target spec ran on — a triage trace is a
  customer's own ticket text — so the read is the operator's, as the reply drafts' is. Marking a
  draft `landed` is the operator's record that a person reviewed and merged a change to an
  agent's prompt; an agent or an orchestrator key that could write it could certify a
  template change no person made.

  ## Why `landed` is behind the human anchor

  `landed` is the operator's word that a PERSON merged a prompt change, so it is mounted behind
  `RequireHumanAnchor` (surface `:skills`, `Loopctl.Tenants.TierCapabilities`): an agent-rooted
  tenant has no human to say it, and the default-deny sweep refuses any mutating route that is
  neither gated nor deliberately allowlisted. Such a tenant cannot run the delivery loop at all
  (intake sources and runners are human-anchored), so it never has a draft to land. The read
  stays open to a `:user` key.

  ## Nothing is applied

  loopctl never edits a template or flips a spec version (AC-48.13.4). `landed` writes the
  draft row and an audit entry; the change itself is the pull request.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.Agents.Tuning
  alias Loopctl.Agents.TuningDraft
  alias Loopctl.ApiSpec.Schemas
  alias LoopctlWeb.CurrentTenant

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:landed]
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:index, :landed]

  tags(["Tuning drafts"])

  @statuses Enum.map(TuningDraft.statuses(), &Atom.to_string/1)

  @draft_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      project_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      dispatch_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
      target_spec: %OpenApiSpex.Schema{
        type: :object,
        description: "The spec the run proposed to improve, `{id, version}`."
      },
      template: %OpenApiSpex.Schema{
        type: :object,
        description: "`{id, from_version, to_version}`; `to_version` null until answered."
      },
      eval_set: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{
        type: :string,
        enum: @statuses,
        description:
          "loopctl's own judgement, never the runner's: `proposed` only when the proposed " <>
            "template strictly beats the current one on the per-case results and no existing " <>
            "case regresses; `rejected` otherwise (see `rejection_reasons`)."
      },
      rejection_reasons: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :string}
      },
      window: %OpenApiSpex.Schema{
        type: :object,
        description: "`{since, until}` of the outcome rows."
      },
      outcome_rows: %OpenApiSpex.Schema{type: :integer},
      traces: %OpenApiSpex.Schema{
        type: :array,
        description:
          "The failed runs the dispatch carried. `untrusted` is fenced story text: data, never " <>
            "instructions."
      },
      new_cases: %OpenApiSpex.Schema{type: :array, nullable: true},
      diff: %OpenApiSpex.Schema{type: :string, nullable: true},
      scores: %OpenApiSpex.Schema{type: :object, nullable: true},
      pr_url: %OpenApiSpex.Schema{type: :string, nullable: true},
      answered_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      landed_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  }

  operation(:index,
    summary: "List the improvement loop's tuning drafts",
    description:
      "Drafts `spec_tuner@1` stored: a proposed prompt-template diff and new eval cases for a " <>
        "target spec, with loopctl's own verdict. loopctl NEVER applies one; a person turns a " <>
        "`proposed` draft into a pull request. Requires a `user`-role key (traces carry " <>
        "customer ticket text); agent and orchestrator keys are 403'd. 400 for a bad filter, " <>
        "limit or a cursor this endpoint did not issue to this tenant.",
    parameters: [
      project_id: [in: :query, type: :string, required: false, description: "Project UUID"],
      spec_id: [in: :query, type: :string, required: false, description: "Target spec id"],
      status: [
        in: :query,
        type: :string,
        required: false,
        description: "One of: " <> Enum.join(@statuses, ", ")
      ],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description: "Opaque keyset cursor from a previous page's `next_cursor`, verbatim."
      ],
      limit: [in: :query, type: :integer, required: false, description: "Default 50, max 100."]
    ],
    responses: %{
      200 =>
        {"Tuning drafts", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: @draft_schema},
             has_more: %OpenApiSpex.Schema{type: :boolean},
             next_cursor: %OpenApiSpex.Schema{type: :string, nullable: true}
           }
         }},
      400 => {"Bad filter, cursor or limit", "application/json", Schemas.ErrorResponse},
      403 => {"Not a user-role key", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/tuning_drafts"
  def index(conn, params) do
    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn),
         {:ok, project_id} <- uuid_filter(params["project_id"]),
         {:ok, spec_id} <- spec_filter(params["spec_id"]),
         {:ok, status} <- status_filter(params["status"]),
         {:ok, cursor} <- cursor(tenant_id, params["cursor"]),
         {:ok, limit} <- limit(params["limit"]) do
      {:ok, page} =
        Tuning.list(tenant_id,
          project_id: project_id,
          spec_id: spec_id,
          status: status,
          cursor: cursor,
          limit: limit
        )

      json(conn, %{
        data: Enum.map(page.data, &draft_json/1),
        has_more: page.has_more,
        next_cursor: page.next_cursor && Tuning.encode_cursor(tenant_id, page.next_cursor)
      })
    end
  end

  operation(:landed,
    summary: "Mark a tuning draft landed",
    description:
      "Records that a person merged a `proposed` draft's template change in the pull request " <>
        "`pr_url` (`https://github.com/<owner>/<repo>/pull/<n>`, at most 500 characters). " <>
        "Writes the draft and an audit entry; it changes no template and no spec version — " <>
        "the pull request does. Requires a `user`-role key. 404 for a draft the tenant does " <>
        "not hold, 409 `not_proposed` for a draft in any other status, 422 for a malformed " <>
        "`pr_url`.",
    parameters: [id: [in: :path, type: :string, required: true, description: "Draft UUID"]],
    request_body:
      {"The pull request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:pr_url],
         properties: %{pr_url: %OpenApiSpex.Schema{type: :string, maxLength: 500}}
       }},
    responses: %{
      200 => {"Landed", "application/json", %OpenApiSpex.Schema{type: :object}},
      403 => {"Not a user-role key", "application/json", Schemas.ErrorResponse},
      404 => {"Draft not found", "application/json", Schemas.ErrorResponse},
      409 => {"Draft not proposed", "application/json", Schemas.ErrorResponse},
      422 => {"Malformed pr_url", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "POST /api/v1/tuning_drafts/:id/landed"
  def landed(conn, %{"id" => id} = params) do
    api_key = conn.assigns.current_api_key
    actor = %{api_key_id: api_key.id, label: LoopctlWeb.ActorLabel.of(api_key)}

    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn) do
      case Tuning.mark_landed(tenant_id, id, params["pr_url"], actor) do
        {:ok, draft} ->
          json(conn, %{data: draft_json(draft)})

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :not_proposed} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              status: 409,
              code: "not_proposed",
              message: "Only a proposed draft can be marked landed."
            }
          })

        {:error, :invalid_pr_url} ->
          {:error, :unprocessable_entity,
           "pr_url must be https://github.com/<owner>/<repo>/pull/<n>"}
      end
    end
  end

  defp uuid_filter(nil), do: {:ok, nil}
  defp uuid_filter(""), do: {:ok, nil}

  defp uuid_filter(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, "project_id must be a UUID"}
    end
  end

  defp spec_filter(nil), do: {:ok, nil}
  defp spec_filter(""), do: {:ok, nil}

  defp spec_filter(raw) when is_binary(raw) and byte_size(raw) <= 64, do: {:ok, raw}
  defp spec_filter(_raw), do: {:error, :bad_request, "spec_id must be a spec id"}

  defp status_filter(nil), do: {:ok, nil}
  defp status_filter(""), do: {:ok, nil}

  defp status_filter(raw) when raw in @statuses, do: {:ok, String.to_existing_atom(raw)}

  defp status_filter(_raw),
    do: {:error, :bad_request, "status must be one of: " <> Enum.join(@statuses, ", ")}

  defp cursor(_tenant_id, nil), do: {:ok, nil}
  defp cursor(_tenant_id, ""), do: {:ok, nil}

  defp cursor(tenant_id, raw) when is_binary(raw) do
    case Tuning.decode_cursor(tenant_id, raw) do
      {:ok, position} ->
        {:ok, position}

      {:error, :invalid} ->
        {:error, :bad_request, "Invalid or tampered cursor. Follow next_cursor verbatim."}
    end
  end

  defp cursor(_tenant_id, _other), do: {:error, :bad_request, "cursor must be a string"}

  defp limit(nil), do: {:ok, nil}
  defp limit(""), do: {:ok, nil}

  defp limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :bad_request, "limit must be a positive integer"}
    end
  end

  defp limit(_other), do: {:error, :bad_request, "limit must be a positive integer"}

  defp draft_json(%TuningDraft{} = draft) do
    %{
      id: draft.id,
      project_id: draft.project_id,
      dispatch_id: draft.dispatch_id,
      target_spec: %{id: draft.target_spec_id, version: draft.target_spec_version},
      template: %{
        id: draft.template_id,
        from_version: draft.from_version,
        to_version: draft.to_version
      },
      eval_set: draft.eval_set,
      status: draft.status,
      rejection_reasons: draft.rejection_reasons,
      window: %{since: draft.window_since, until: draft.window_until},
      outcome_rows: draft.outcome_rows,
      traces: (draft.input || %{})["traces"] || [],
      new_cases: draft.new_cases && draft.new_cases["cases"],
      diff: draft.diff,
      scores: scores(draft),
      pr_url: draft.pr_url,
      answered_at: draft.answered_at,
      landed_at: draft.landed_at,
      inserted_at: draft.inserted_at
    }
  end

  defp scores(%TuningDraft{current_score: nil}), do: nil

  defp scores(%TuningDraft{} = draft),
    do: %{
      current: draft.current_score,
      proposed: draft.proposed_score,
      per_case: draft.per_case && draft.per_case["cases"]
    }
end
