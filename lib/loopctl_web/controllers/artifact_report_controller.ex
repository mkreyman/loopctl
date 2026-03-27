defmodule LoopctlWeb.ArtifactReportController do
  @moduledoc """
  Controller for artifact report submission and listing.

  - `POST /api/v1/stories/:id/artifacts` -- submit an artifact report (agent or orchestrator)
  - `GET /api/v1/stories/:id/artifacts` -- list artifact reports for a story

  Submission requires exact_role: agent or orchestrator.
  Listing requires minimum role: agent.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Artifacts
  alias Loopctl.WorkBreakdown.Stories

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:agent, :orchestrator]] when action in [:create]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:index]

  @doc """
  POST /api/v1/stories/:id/artifacts

  Submits an artifact report for a story. The reporter_agent_id is set from
  the authenticated API key's agent_id. The reported_by field is derived
  from the API key's role.
  """
  def create(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _story} <- Stories.get_story(tenant_id, story_id) do
      attrs =
        %{
          "artifact_type" => params["artifact_type"],
          "path" => params["path"],
          "exists" => params["exists"],
          "details" => params["details"]
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      reported_by = derive_reported_by(api_key.role)

      case Artifacts.create_artifact_report(tenant_id, story_id, attrs,
             agent_id: api_key.agent_id,
             reported_by: reported_by,
             actor_id: api_key.id,
             actor_label: "#{reported_by}:#{api_key.name}"
           ) do
        {:ok, report} ->
          conn
          |> put_status(:created)
          |> json(%{artifact_report: report})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/v1/stories/:id/artifacts

  Lists all artifact reports for a story with pagination.
  """
  def index(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _story} <- Stories.get_story(tenant_id, story_id) do
      opts =
        []
        |> maybe_add_opt(:page, parse_int(params["page"]))
        |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

      {:ok, result} = Artifacts.list_artifact_reports(tenant_id, story_id, opts)

      json(conn, %{
        data: result.data,
        meta: %{
          page: result.page,
          page_size: result.page_size,
          total_count: result.total,
          total_pages: ceil_div(result.total, result.page_size)
        }
      })
    end
  end

  # --- Private helpers ---

  defp derive_reported_by(:agent), do: :agent
  defp derive_reported_by(:orchestrator), do: :orchestrator
  # Superadmin falls back to orchestrator if this endpoint ever opens to them
  defp derive_reported_by(_), do: :orchestrator

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
