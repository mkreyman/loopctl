defmodule LoopctlWeb.WorkItemNoteController do
  @moduledoc """
  A work item's notes (US-52.17), for the session holding it and the sessions after it.

  - `POST /api/v1/stories/:id/notes` — append a note (the item's holder, or orchestrator+)
  - `GET /api/v1/stories/:id/notes` — read them, oldest first, with the newest per section
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.WorkItems
  alias Loopctl.WorkItems.Note

  action_fallback LoopctlWeb.FallbackController

  # A story exists only under a human-anchored :work project, so the anchor refuses no holder
  # a note it could have written; it is mounted for the same reason every work-breakdown
  # write mounts it (`Loopctl.Tenants.TierCapabilities`).
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]
  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Work items"])

  @note_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      story_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      holder_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
      section: %OpenApiSpex.Schema{type: :string, enum: Note.sections()},
      body: %OpenApiSpex.Schema{type: :string},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  }

  operation(:create,
    summary: "Write a note on a work item",
    description:
      "Appends a note to the story (`section`: #{Enum.join(Note.sections(), ", ")}; " <>
        "`body`: 1 to #{Note.max_body_bytes()} bytes, refused if it looks like a " <>
        "credential) and records a `note_written` event on its log, together or not at " <>
        "all. The writer is the session holding the story (the key's holder is the " <>
        "story's `assigned_holder_id`) or an orchestrator, user or superadmin key. A " <>
        "repeated `idempotency_key` returns the first note and writes nothing.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Note", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:section, :body],
         properties: %{
           section: %OpenApiSpex.Schema{type: :string, enum: Note.sections()},
           body: %OpenApiSpex.Schema{type: :string, maxLength: Note.max_body_bytes()},
           idempotency_key: %OpenApiSpex.Schema{type: :string, maxLength: 200}
         }
       }},
    responses: %{
      201 =>
        {"Note written (or the first note, on a repeated idempotency_key)", "application/json",
         %OpenApiSpex.Schema{type: :object, properties: %{note: @note_schema}}},
      404 => {"No such story in this tenant", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`held_by_other_holder`: another session holds the story. `not_holder`: nobody " <>
           "holds it, so only an orchestrator+ key may write. `idempotency_key_reused`: " <>
           "another writer's note already carries this key; nothing was written.",
         "application/json", Schemas.ErrorResponse},
      422 =>
        {"Unknown section, empty or oversized body, or a body that looks like a credential",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "Read a work item's notes",
    description:
      "The story's notes oldest first, optionally one section. The first page also " <>
        "carries `current`: the newest note of each section. `limit` defaults to " <>
        "#{elem(WorkItems.page_limits(), 0)}, at most #{elem(WorkItems.page_limits(), 1)}; " <>
        "pass `next_cursor` back as `after`.",
    parameters: [
      id: [in: :path, type: :string, description: "Story UUID"],
      section: [in: :query, type: :string, description: "One section"],
      limit: [in: :query, type: :integer, description: "Page size"],
      after: [in: :query, type: :string, description: "The previous page's next_cursor"]
    ],
    responses: %{
      200 =>
        {"Notes", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: @note_schema},
             current: %OpenApiSpex.Schema{type: :object, nullable: true},
             has_more: %OpenApiSpex.Schema{type: :boolean},
             next_cursor: %OpenApiSpex.Schema{type: :string, nullable: true}
           }
         }},
      404 => {"No such story in this tenant", "application/json", Schemas.ErrorResponse},
      422 => {"Unknown section or an invalid cursor", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  def create(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    # The author is the authenticating key, resolved here and never from the request.
    author = %{api_key_id: api_key.id, role: api_key.role, holder_id: api_key.holder_id}
    attrs = Map.take(params, ["section", "body", "idempotency_key"])

    with {:ok, note} <- WorkItems.write_note(api_key.tenant_id, story_id, attrs, author) do
      conn
      |> put_status(:created)
      |> json(%{note: render_note(note)})
    end
  end

  def index(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    opts = [
      section: params["section"],
      limit: parse_limit(params["limit"]),
      after: params["after"]
    ]

    case WorkItems.list_notes(api_key.tenant_id, story_id, opts) do
      {:ok, page} ->
        json(conn, %{
          data: Enum.map(page.data, &render_note/1),
          current: page.current && Map.new(page.current, fn {s, n} -> {s, render_note(n)} end),
          has_more: page.has_more,
          next_cursor: page.next_cursor
        })

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, refusal} when refusal in [:invalid_cursor, :invalid_section] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{status: 422, code: Atom.to_string(refusal), message: refusal_text(refusal)}
        })
    end
  end

  defp refusal_text(:invalid_cursor), do: "after is not a cursor this endpoint returned."

  defp refusal_text(:invalid_section),
    do: "section is one of: " <> Enum.join(Note.sections(), ", ") <> "."

  defp parse_limit(nil), do: nil

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_limit(value) when is_integer(value), do: value
  defp parse_limit(_value), do: nil

  defp render_note(%Note{} = note) do
    %{
      id: note.id,
      story_id: note.story_id,
      holder_id: note.holder_id,
      section: note.section,
      body: note.body,
      inserted_at: note.inserted_at
    }
  end
end
