defmodule LoopctlWeb.WorkItemController do
  @moduledoc """
  Opening an interactive session's work item (US-52.18).

  - `POST /api/v1/work_items` — the session holding a holder credential opens the item for
    the branch its worktree is on, already claimed by it.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.WorkItems
  alias Loopctl.WorkItems.Open
  alias Plug.Conn.Status

  action_fallback LoopctlWeb.FallbackController

  # An item is a story under a :work project, so the open is a work-breakdown write behind
  # the human anchor, listed in `Loopctl.Tenants.TierCapabilities`.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]
  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Work items"])

  @item_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      number: %OpenApiSpex.Schema{type: :string},
      title: %OpenApiSpex.Schema{type: :string},
      project_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      epic_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      agent_status: %OpenApiSpex.Schema{type: :string},
      assigned_holder_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
      branch: %OpenApiSpex.Schema{type: :string}
    }
  }

  operation(:create,
    summary: "Open the work item for an interactive session's branch",
    description:
      "Creates one story in the project `repo_url` resolves to, already `implementing` and " <>
        "held by the caller's holder, with a stage row at `implementing` naming `branch`. " <>
        "The epic is `epic_id`, else the target epic of the project's live intake source; " <>
        "the title defaults to the branch. One item per (project, branch): reopening the " <>
        "caller's own item returns it (200), an unheld item is claimed back for the caller " <>
        "(200), and the caller's one held item with no branch takes this branch (200). " <>
        "Needs a holder credential (POST /api/v1/holders).",
    request_body:
      {"Work item", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:repo_url, :branch],
         properties: %{
           repo_url: %OpenApiSpex.Schema{type: :string},
           branch: %OpenApiSpex.Schema{type: :string, maxLength: Open.max_branch_bytes()},
           title: %OpenApiSpex.Schema{type: :string, maxLength: 500},
           epic_id: %OpenApiSpex.Schema{type: :string, format: :uuid}
         }
       }},
    responses: %{
      201 =>
        {"Item created", "application/json",
         %OpenApiSpex.Schema{type: :object, properties: %{work_item: @item_schema}}},
      200 =>
        {"The existing item (`outcome`: existing, claimed or branch_recorded)",
         "application/json",
         %OpenApiSpex.Schema{type: :object, properties: %{work_item: @item_schema}}},
      403 =>
        {"`holder_credential_required`: the key is not a holder credential", "application/json",
         Schemas.ErrorResponse},
      404 =>
        {"`project_not_found`: no project of this tenant has this repo; " <>
           "`epic_not_found`: epic_id is not an epic of that project", "application/json",
         Schemas.ErrorResponse},
      409 =>
        {"`branch_held`: another holder's open item has this branch (`story_id`, " <>
           "`holder_id`); `holder_ended`; `ambiguous_project`; `story_held` (escalated)",
         "application/json", Schemas.ErrorResponse},
      422 =>
        {"`no_target_epic`: pass epic_id; `invalid_branch`; `invalid_repo_url`",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    attrs = Map.take(params, ["repo_url", "branch", "title", "epic_id"])

    case WorkItems.open_interactive(api_key.tenant_id, opener(api_key), attrs) do
      {:ok, outcome, story} ->
        conn
        |> put_status(if outcome == :created, do: :created, else: :ok)
        |> json(%{outcome: Atom.to_string(outcome), work_item: render_item(story, attrs)})

      {:error, {:branch_held, story_id, holder_id}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            status: 409,
            code: "branch_held",
            message: "Another session's open work item already has this branch.",
            story_id: story_id,
            holder_id: holder_id
          }
        })

      {:error, refusal} when is_atom(refusal) ->
        render_refusal(conn, refusal)

      {:error, other} ->
        {:error, other}
    end
  end

  # The opener is the authenticating key, resolved here and never from the request.
  defp opener(api_key) do
    dispatch_id =
      case Dispatches.dispatch_for_api_key(api_key.tenant_id, api_key.id) do
        {:ok, dispatch} -> dispatch.id
        :none -> nil
      end

    %{
      api_key_id: api_key.id,
      agent_id: api_key.agent_id,
      holder_id: api_key.holder_id,
      dispatch_id: dispatch_id,
      minting_lineage: Dispatches.minting_lineage_for_api_key(api_key.tenant_id, api_key.id)
    }
  end

  @refusals %{
    holder_credential_required:
      {:forbidden, "This route needs a holder credential: register the session first."},
    project_not_found: {:not_found, "No project of this tenant has this repo_url."},
    epic_not_found: {:not_found, "epic_id is not an epic of the repo's project."},
    holder_ended: {:conflict, "This holder has ended; register the session again."},
    ambiguous_project: {:conflict, "More than one project has this repo_url."},
    story_held: {:conflict, "The branch's work item is escalated; a human resolves it."},
    no_target_epic:
      {:unprocessable_entity,
       "The repo's project has no single intake target epic: pass epic_id."},
    invalid_branch:
      {:unprocessable_entity,
       "branch is a branch name: 1 to #{Open.max_branch_bytes()} bytes, no whitespace, not HEAD."},
    invalid_repo_url: {:unprocessable_entity, "repo_url is required."}
  }

  defp render_refusal(conn, refusal) do
    case Map.fetch(@refusals, refusal) do
      {:ok, {status, message}} ->
        conn
        |> put_status(status)
        |> json(%{
          error: %{
            status: Status.code(status),
            code: Atom.to_string(refusal),
            message: message
          }
        })

      :error ->
        {:error, refusal}
    end
  end

  defp render_item(story, attrs) do
    %{
      id: story.id,
      number: story.number,
      title: story.title,
      project_id: story.project_id,
      epic_id: story.epic_id,
      agent_status: story.agent_status,
      assigned_holder_id: story.assigned_holder_id,
      branch: attrs["branch"]
    }
  end
end
