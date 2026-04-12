defmodule LoopctlWeb.AcceptanceCriteriaController do
  @moduledoc """
  US-26.4.1 — REST API for story acceptance criteria.
  """

  use LoopctlWeb, :controller

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.StoryAcceptanceCriterion

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  @doc "GET /api/v1/stories/:story_id/acceptance_criteria"
  def index(conn, %{"story_id" => story_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    criteria =
      from(c in StoryAcceptanceCriterion,
        where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
        order_by: [asc: c.ac_id]
      )
      |> AdminRepo.all()

    json(conn, %{data: Enum.map(criteria, &serialize/1)})
  end

  defp serialize(c) do
    %{
      id: c.id,
      ac_id: c.ac_id,
      description: c.description,
      verification_criterion: c.verification_criterion,
      status: c.status,
      verified_at: c.verified_at,
      evidence_path: c.evidence_path
    }
  end
end
