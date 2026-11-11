defmodule LoopctlWeb.StoryChangeController do
  @moduledoc """
  `GET /api/v1/stories/:id/changes` — the chg changes bound to a story and each one's applied
  events (US-47.7, Epic 47 PRD §4). A thin HTTP shell over `Loopctl.Changes.story_changes/2`,
  which holds the ordering, the bounds and the tenant scoping.

  READS STAY OPEN, like the story's stage and history: `role: :agent` with the hierarchy, so
  any key of the tenant reads it. A story is visible to every key of its tenant, and nothing
  here is more private than the story itself — the event `data` payload, the one field chg
  authors freely, is not returned.

  Another tenant's story id answers exactly as an unknown one: 404.
  """

  use LoopctlWeb, :controller

  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Changes
  alias LoopctlWeb.CurrentTenant
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show]

  # Read once from `Loopctl.Changes`, where the query enforces them, and used by both the
  # operation spec and the response's `meta`, so the documented bound is the enforced one.
  @max_events_per_change Changes.max_events_per_change()
  @max_bindings Changes.max_bindings()

  tags(["Stories"])

  @event_schema %Schema{
    type: :object,
    description: "An APPLIED chg event of the change. `data` and `effect` are not returned.",
    properties: %{
      event_seq: %Schema{type: :integer, description: "chg's per-change sequence, from 1."},
      kind: %Schema{type: :string, description: "The chg event kind, e.g. `submitted`."},
      revision: %Schema{type: :integer},
      sha: %Schema{type: :string},
      occurred_at: %Schema{type: :string, format: :"date-time"},
      applied_at: %Schema{type: :string, format: :"date-time"}
    }
  }

  @binding_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      repo: %Schema{type: :string, description: "The repository, downcased."},
      change_id: %Schema{type: :string},
      current: %Schema{
        type: :boolean,
        description: "True for the one binding not superseded — the change the story follows."
      },
      superseded_at: %Schema{type: :string, format: :"date-time", nullable: true},
      submitter_not_claimant: %Schema{
        type: :boolean,
        description:
          "True when whoever submitted the change did not hold the story's claim. " <>
            "Informational: a binding never changes the story's implementer of record."
      },
      inserted_at: %Schema{type: :string, format: :"date-time"},
      applied_event_count: %Schema{
        type: :integer,
        description: "How many applied events the change has in all."
      },
      events_truncated: %Schema{
        type: :boolean,
        description:
          "True when `applied_event_count` exceeds the #{@max_events_per_change} listed; " <>
            "the listed ones are then the newest."
      },
      events: %Schema{type: :array, items: @event_schema, maxItems: @max_events_per_change}
    }
  }

  operation(:show,
    summary: "Read the chg changes bound to a story",
    description:
      "The story's change bindings OLDEST FIRST (so the current one is last), each with its " <>
        "change's APPLIED events in `event_seq` order — an event held ahead of a gap is not " <>
        "listed. Bounded: at most #{@max_bindings} bindings (the newest, so the current " <>
        "one is always present; `binding_count` is the total) and at most " <>
        "#{@max_events_per_change} events per change (the newest; `events_truncated` says " <>
        "when more exist). The event `data` payload is not returned.\n\n" <>
        "Any key of the tenant may read it (role `agent` and above, so no role is refused). " <>
        "404 for a story that " <>
        "is not the tenant's — another tenant's id answers exactly as an unknown one.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 =>
        {"The story's bindings and their applied events", "application/json",
         %Schema{
           type: :object,
           properties: %{
             story_id: %Schema{type: :string, format: :uuid},
             bindings: %Schema{type: :array, items: @binding_schema, maxItems: @max_bindings},
             binding_count: %Schema{type: :integer},
             meta: %Schema{
               type: :object,
               properties: %{
                 order: %Schema{type: :string, enum: ["oldest_first"]},
                 max_bindings: %Schema{type: :integer, enum: [@max_bindings]},
                 max_events_per_change: %Schema{type: :integer, enum: [@max_events_per_change]}
               }
             }
           }
         }},
      400 =>
        {"A superadmin key without X-Impersonate-Tenant", "application/json",
         Schemas.ErrorResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/stories/:id/changes"
  def show(conn, %{"id" => story_id}) do
    with {:ok, tenant_id} <- CurrentTenant.fetch_id(conn),
         {:ok, changes} <- Changes.story_changes(tenant_id, story_id) do
      json(conn, %{
        story_id: changes.story_id,
        bindings: Enum.map(changes.bindings, &render_binding/1),
        binding_count: changes.binding_count,
        meta: %{
          order: "oldest_first",
          max_bindings: @max_bindings,
          max_events_per_change: @max_events_per_change
        }
      })
    end
  end

  defp render_binding(%{binding: binding, events: events, applied_event_count: count}) do
    %{
      id: binding.id,
      repo: binding.repo,
      change_id: binding.change_id,
      current: is_nil(binding.superseded_at),
      superseded_at: binding.superseded_at,
      submitter_not_claimant: binding.submitter_not_claimant,
      inserted_at: binding.inserted_at,
      applied_event_count: count,
      events_truncated: count > length(events),
      events: Enum.map(events, &render_event/1)
    }
  end

  defp render_event(event) do
    %{
      event_seq: event.event_seq,
      kind: event.kind,
      revision: event.revision,
      sha: event.sha,
      occurred_at: event.occurred_at,
      applied_at: event.applied_at
    }
  end
end
