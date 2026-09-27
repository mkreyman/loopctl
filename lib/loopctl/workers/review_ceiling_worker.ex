defmodule Loopctl.Workers.ReviewCeilingWorker do
  @moduledoc """
  US-45.3 — moves a story's delivery stage to `escalated` over the control-only
  `:review_ceiling` edge for every review ceiling the thread recorded and the stage machine has
  not caught up with. Runs every minute via Oban Cron.

  ## Why the escalation is durable this way

  The review's verdict records the escalation as a thread ENTRY in the verdict's own
  transaction (`Loopctl.Threads.record_judgement/5`), so the decision can never be lost by a
  crash between the commit and a follow-up. What can be late is the stage move. This worker
  selects by the gap itself — an escalation entry whose stage row is still IN FLIGHT under the
  SAME claim the review judged — so every candidate has work, and one that lands drops out of
  the next run: `escalated` is not in flight.

  **When it proves unnecessary it stops by construction.** A row that left the in-flight stages
  (escalated by someone else, merged, released) or whose claim moved on is no longer a
  candidate. The only way back into flight is a new claim, which bumps the epoch, and a new
  claim is one this entry never judged. `reconcile/2` is the same selection scoped to one
  story, on the RLS repo, which `Loopctl.Delivery.RunnerReviews` calls once right after the
  verdict, so the ordinary case does not wait for the next tick.

  The candidate read is fleet-wide on AdminRepo (BYPASSRLS, so its explicit predicates are the
  only scoping), as `HealRunnerCapacityWorker`'s is. Each move goes through
  `Loopctl.Delivery.Escalations.escalate_as_control/3`, a compare-and-set that re-decides on
  the RLS repo, so the read is advisory and two overlapping runs escalate nothing twice.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 50, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Review

  @batch 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    candidates() |> Enum.each(&escalate/1)
    :ok
  end

  @doc """
  One attempt, now, for `story_id`'s outstanding review ceiling, if it has one. Answers `:ok`
  either way: the cron run is what retries.
  """
  @spec reconcile(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def reconcile(tenant_id, story_id) do
    # On the RLS repo, scoped to the tenant: the caller knows it, and needs no fleet-wide read.
    {:ok, candidates} =
      Repo.with_tenant(tenant_id, fn ->
        candidates_query()
        |> where([e], e.tenant_id == ^tenant_id and e.story_id == ^story_id)
        |> Repo.all()
      end)

    Enum.each(candidates, &escalate/1)
  end

  defp candidates, do: AdminRepo.all(candidates_query())

  defp candidates_query do
    in_flight = StageMachine.in_flight_stages()

    from e in Entry,
      join: r in Review,
      on: r.id == e.review_id and r.tenant_id == e.tenant_id,
      join: s in StoryStage,
      on: s.tenant_id == e.tenant_id and s.story_id == e.story_id,
      where: e.kind == :escalation and e.author_principal == ^Threads.review_ceiling_principal(),
      # The epoch clause is not only an optimisation: `escalate_as_control/3` would refuse a
      # moved claim anyway, but the row would stay a candidate, and oldest-first with a batch
      # limit lets enough such rows starve every live ceiling behind them.
      where: s.stage in ^in_flight and s.claim_epoch == r.claim_epoch,
      order_by: [asc: e.inserted_at],
      limit: @batch,
      select: %{
        tenant_id: e.tenant_id,
        story_id: e.story_id,
        claim_epoch: r.claim_epoch,
        reason: e.body
      }
  end

  defp escalate(candidate) do
    case Escalations.escalate_as_control(candidate.tenant_id, candidate.story_id,
           claim_epoch: candidate.claim_epoch,
           reason: candidate.reason,
           actor_label: Threads.review_ceiling_principal(),
           actor_lineage: []
         ) do
      {:ok, _row} ->
        :ok

      error ->
        Logger.warning(
          "review_ceiling not yet moved to escalated; the next run retries: " <>
            "#{inspect(error)} tenant_id=#{candidate.tenant_id} story_id=#{candidate.story_id}",
          tenant_id: candidate.tenant_id,
          story_id: candidate.story_id
        )
    end
  end
end
