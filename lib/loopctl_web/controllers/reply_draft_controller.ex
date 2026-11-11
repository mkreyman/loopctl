defmodule LoopctlWeb.ReplyDraftController do
  @moduledoc """
  `GET /api/v1/projects/:project_id/reply_drafts` (Epic 48, US-48.9): the reply drafts
  `reply_draft@1` stored for a project's support tickets, newest first, keyset-paginated.

  ## Why `role: :user`

  A draft's body was written by a session that read a customer's ticket, and it is meant to be
  sent to that customer in the operator's name. It is ticket-derived text about a third party,
  and the person who decides whether it goes out is the operator — so the read is the
  operator's, not an agent's or an orchestrator's. An agent key reaching it would hand any
  dispatched session every customer's correspondence for the project.

  ## Nothing is sent

  loopctl never sends a draft: this endpoint only reads what is stored. A `refused` draft
  carries the screen that refused it and its signal codes, and no body.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Projects
  alias Loopctl.ReplyDrafts
  alias Loopctl.ReplyDrafts.ReplyDraft
  alias LoopctlWeb.CurrentTenant
  alias LoopctlWeb.Helpers.ProjectId

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:index]

  tags(["Reply drafts"])

  @draft_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      project_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      story_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      dispatch_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The dispatch that drafted it; null when it was refused before dispatch."
      },
      ticket_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The support ticket the draft answers, from the story's intake record."
      },
      status: %OpenApiSpex.Schema{type: :string, enum: ["drafted", "refused"]},
      body: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "The drafted reply. Null on a `refused` draft: a body the screen refused is not stored."
      },
      screen_code: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Why it was refused: `injection_detector_draft`, `payload_too_large` or " <>
            "`ticket_missing`. Null on a `drafted` one."
      },
      screen_signals: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :string},
        description: "The injection detector's `<signal>:<field>` codes on a refusal."
      },
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  }

  operation(:index,
    summary: "List a project's reply drafts",
    description:
      "Reply drafts `reply_draft@1` stored for support tickets triage rejected or escalated, " <>
        "newest first. loopctl NEVER sends a draft anywhere; a person reads it here and sends " <>
        "it or not. Requires a `user`-role key (the bodies are drafted from customer ticket " <>
        "text); agent and orchestrator keys are 403'd. 404 for a project the tenant does not " <>
        "hold, 400 for a cursor this endpoint did not issue to this tenant.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID", required: true],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Opaque keyset cursor from a previous page's `next_cursor`, followed verbatim. " <>
            "Integrity-protected and tenant-bound; any other string is rejected with 400."
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size, default 50, at most 100."
      ]
    ],
    responses: %{
      200 =>
        {"Reply drafts", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: @draft_schema},
             has_more: %OpenApiSpex.Schema{type: :boolean},
             next_cursor: %OpenApiSpex.Schema{
               type: :string,
               nullable: true,
               description: "Continuation token; null on the last page."
             }
           }
         }},
      400 => {"Bad cursor or limit", "application/json", Schemas.ErrorResponse},
      403 => {"Not a user-role key", "application/json", Schemas.ErrorResponse},
      404 => {"Project not found", "application/json", Schemas.ErrorResponse},
      422 => {"Malformed project_id", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/projects/:project_id/reply_drafts"
  def index(conn, %{"project_id" => project_id} = params) do
    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn),
         :ok <- ProjectId.validate(project_id),
         {:ok, _project} <- Projects.get_project(tenant_id, project_id),
         {:ok, cursor} <- cursor(tenant_id, params["cursor"]),
         {:ok, limit} <- limit(params["limit"]) do
      {:ok, page} = ReplyDrafts.list(tenant_id, project_id, cursor: cursor, limit: limit)

      json(conn, %{
        data: Enum.map(page.data, &draft_json/1),
        has_more: page.has_more,
        next_cursor: page.next_cursor && ReplyDrafts.encode_cursor(tenant_id, page.next_cursor)
      })
    end
  end

  defp cursor(_tenant_id, nil), do: {:ok, nil}
  defp cursor(_tenant_id, ""), do: {:ok, nil}

  defp cursor(tenant_id, raw) when is_binary(raw) do
    case ReplyDrafts.decode_cursor(tenant_id, raw) do
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

  defp draft_json(%ReplyDraft{} = draft) do
    %{
      id: draft.id,
      project_id: draft.project_id,
      story_id: draft.story_id,
      dispatch_id: draft.dispatch_id,
      ticket_id: draft.ticket_id,
      status: draft.status,
      body: draft.body,
      screen_code: draft.screen_code,
      screen_signals: draft.screen_signals,
      inserted_at: draft.inserted_at
    }
  end
end
