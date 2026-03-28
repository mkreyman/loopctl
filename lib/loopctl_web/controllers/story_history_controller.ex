defmodule LoopctlWeb.StoryHistoryController do
  @moduledoc """
  Controller for the story history shortcut endpoint.

  GET /api/v1/stories/:id/history — full audit trail for a specific story.
  Returns all audit log entries where entity_type="story" and entity_id=:id,
  ordered chronologically (ascending by inserted_at).

  Accessible to agent role and above.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Audit

  action_fallback LoopctlWeb.FallbackController

  tags(["Stories"])

  operation(:show,
    summary: "Get story history",
    description: "Returns the full audit trail for a specific story.",
    parameters: [
      id: [in: :path, type: :string, description: "Story UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Story history", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # No RequireRole needed: within :authenticated pipeline, accessible to all
  # roles including agent. Agents need story history to understand prior
  # verification feedback (US-9.2).

  @doc """
  GET /api/v1/stories/:id/history

  Returns paginated, chronologically-ordered audit trail for a story.
  Validates the story exists before querying audit entries.
  """
  def show(conn, %{"id" => story_id} = params) do
    # [US-6.2 dependency] When Story schema is implemented, validate the story
    # exists and belongs to this tenant before querying the audit log.
    # For now, we validate the UUID format and query the audit log directly.
    # If no audit entries exist, the story is treated as not found since
    # we cannot verify its existence without the Story schema.
    with {:ok, tenant_id} <- require_tenant(conn),
         {:ok, _uuid} <- validate_uuid(story_id),
         {:ok, result} <- query_history(tenant_id, story_id, params) do
      json(conn, %{
        data: Enum.map(result.data, &entry_json/1),
        pagination: %{
          total: result.total,
          page: result.page,
          page_size: result.page_size
        }
      })
    end
  end

  defp validate_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp query_history(tenant_id, story_id, params) do
    opts =
      []
      |> maybe_put_integer(:page, params["page"])
      |> maybe_put_integer(:page_size, params["page_size"])

    case Audit.entity_history(tenant_id, "story", story_id, opts) do
      {:ok, %{data: [], total: 0} = result} ->
        # [US-6.2 dependency] When Story schema exists, this should check if
        # the story exists but has no audit entries (return empty 200) vs.
        # the story not existing at all (return 404). For now, we check if
        # ANY audit entry references this entity_id regardless of entity_type.
        case check_entity_exists(tenant_id, story_id) do
          true -> {:ok, result}
          false -> {:error, :not_found}
        end

      {:ok, result} ->
        {:ok, result}
    end
  end

  defp check_entity_exists(tenant_id, entity_id) do
    # Check if any audit entry exists for this entity_id (any type)
    # This is a temporary heuristic until the Story schema is available.
    import Ecto.Query

    query =
      Loopctl.Audit.AuditLog
      |> where([a], a.tenant_id == ^tenant_id and a.entity_id == ^entity_id)
      |> limit(1)
      |> select([a], a.id)

    Loopctl.AdminRepo.one(query) != nil
  end

  defp entry_json(entry) do
    %{
      id: entry.id,
      action: entry.action,
      actor_type: entry.actor_type,
      actor_id: entry.actor_id,
      actor_label: entry.actor_label,
      old_state: entry.old_state,
      new_state: entry.new_state,
      metadata: entry.metadata,
      inserted_at: entry.inserted_at
    }
  end

  defp maybe_put_integer(opts, _key, nil), do: opts

  defp maybe_put_integer(opts, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> Keyword.put(opts, key, n)
      :error -> opts
    end
  end

  defp maybe_put_integer(opts, key, value) when is_integer(value) do
    Keyword.put(opts, key, value)
  end

  defp require_tenant(conn) do
    case conn.assigns[:current_tenant] do
      %{id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}
    end
  end
end
