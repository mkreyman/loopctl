defmodule Loopctl.Delivery.ImplementerStart do
  @moduledoc """
  Starts a delivery-loop story's custody lifecycle on the implementer's behalf (US-48.18).

  `Loopctl.Delivery.Placement` claims a story and mints a `start_cap` for the session
  dispatch inside the claim's transaction, but nothing ever spent it: the runner moves the
  stage row `worktree -> implementing` and the story's `agent_status` stayed `:assigned` for
  the rest of its life. `report` needs `:implementing`, so a pr-route story could never be
  reported, reviewed or verified, and `Progress.merge_custody_status/1` was never `:ok`.

  `ensure_started/3` calls `Progress.start_story/3` with the identity the CLAIM recorded —
  the story's `assigned_agent_id` and the lineage of its `implementer_dispatch_id` row —
  never anything a runner message carries. It spends the live `start_cap` the claim minted
  for that lineage, and only when none is live (the 1-hour TTL ran out, or a tenant whose
  claim minted none) mints one for the same lineage, exactly as `recover-cap` would. On a
  tenant with no audit key there is nothing to mint and `start_story/3`'s pre-v2 path takes a
  nil cap.

  It is called from two places, and both are needed:

  - `Loopctl.Delivery.RunnerStages`, after a runner's `worktree -> implementing` commits (and
    on that message's replay), so the custody state follows the stage as it moves;
  - `Loopctl.Agents.VerifyVerdict`, before it reports, so a story claimed before this
    release — or one whose start failed transiently — is started before the verdict needs it.

  A story already past `:assigned` is answered `{:ok, :already_started}` and nothing is read
  beyond it.
  """

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Story

  @type error ::
          :not_found
          | :not_claimed
          | :missing_implementer_dispatch
          | :unresolvable_dispatch_lineage
          | term()

  @doc """
  Moves `story_id` from `:assigned` to `:implementing` as its assigned agent.

  Returns `{:ok, :started}`, `{:ok, :already_started}` for a story past `:assigned`, or
  `{:error, reason}`: `:not_claimed` for a story at `:pending` (nothing to start),
  `:missing_implementer_dispatch` / `:unresolvable_dispatch_lineage` when there is no
  dispatch row to take the lineage from, or whatever `Progress.start_story/3` refused.
  """
  @spec ensure_started(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, :started | :already_started} | {:error, error()}
  def ensure_started(tenant_id, story_id, opts \\ []) do
    case AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      %Story{agent_status: :assigned} = story -> start(tenant_id, story, opts)
      %Story{agent_status: :pending} -> {:error, :not_claimed}
      %Story{} -> {:ok, :already_started}
    end
  end

  # A story-lifecycle write with no plug in front of it, so it carries the custody surface's two
  # gates itself, as `Placement` does: a halted tenant starts nothing (`VerifyVerdict` calls this
  # again before it reports, so a start skipped during a halt happens once the halt is cleared),
  # and a tenant that is not human-anchored has no custody surface at all.
  defp start(tenant_id, story, opts) do
    with :ok <- custody_open(tenant_id),
         {:ok, lineage} <- implementer_lineage(tenant_id, story) do
      case Progress.start_story(tenant_id, story.id,
             agent_id: story.assigned_agent_id,
             cap_id: start_cap_id(tenant_id, story.id, lineage),
             lineage: lineage,
             claim_epoch: story.claim_epoch,
             actor_label: Keyword.get(opts, :actor_label, "control:implementer_start")
           ) do
        {:ok, _story} -> {:ok, :started}
        {:error, reason} -> settle_race(tenant_id, story.id, reason)
      end
    end
  end

  defp custody_open(tenant_id) do
    if Runners.custody_halted?(tenant_id),
      do: {:error, :tenant_halted},
      else: Tenants.require_human_anchor(tenant_id)
  end

  # The lineage comes from the dispatch row the claim recorded and nowhere else.
  defp implementer_lineage(_tenant_id, %Story{implementer_dispatch_id: nil}),
    do: {:error, :missing_implementer_dispatch}

  defp implementer_lineage(tenant_id, %Story{implementer_dispatch_id: id}) do
    case Dispatches.get_dispatch(tenant_id, id) do
      {:ok, %Dispatch{lineage_path: [_ | _] = lineage}} -> {:ok, lineage}
      _ -> {:error, :unresolvable_dispatch_lineage}
    end
  end

  defp start_cap_id(tenant_id, story_id, lineage) do
    case Enum.find(Capabilities.list_for_lineage(tenant_id, story_id, lineage), &start_cap?/1) do
      %{id: id} ->
        id

      nil ->
        case Capabilities.mint(tenant_id, "start_cap", story_id, lineage) do
          {:ok, %{id: id}} ->
            id

          # No usable key: `start_story/3` decides — a keyed tenant refuses the nil cap
          # (`missing_capability`), an unkeyed one takes its pre-v2 path.
          {:error, _reason} ->
            nil
        end
    end
  end

  defp start_cap?(%{typ: "start_cap"}), do: true
  defp start_cap?(_cap), do: false

  # Two callers can race to start one story (a runner's replayed `implementing` and a
  # verdict). The loser's `invalid_transition` is not a failure when the winner left the
  # story started.
  defp settle_race(tenant_id, story_id, reason) do
    case AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id) do
      %Story{agent_status: status} when status not in [:pending, :assigned] ->
        {:ok, :already_started}

      _ ->
        Logger.warning(
          "implementer start refused: tenant_id=#{tenant_id} story_id=#{story_id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
