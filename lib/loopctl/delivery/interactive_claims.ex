defmodule Loopctl.Delivery.InteractiveClaims do
  @moduledoc """
  A claim a session makes ITSELF, with no runner placement (US-45.9).

  A placement records its claim's route on the dispatch ledger and moves the stage row
  `queued -> claimed` itself. An interactive claim has neither, so every reader of the route
  saw `pr`, and nothing ever moved its stage. This module gives it both, and nothing more.

  ## The route, bound once

  `record_route/3` runs INSIDE the claim's transaction (`Progress.claim_story/3`,
  `BulkOperations`), after `Stages.follow_claim/4`. When the story's project has exactly one
  live intake source it writes a `Loopctl.Delivery.ClaimRoute` for the new epoch: the source's
  base branch and, in thread mode, the thread branch. Every reader then sees it through
  `DispatchLedger.route_rows_query/0` exactly as it sees a placement's, and none of them reads
  the source again, so repointing or re-moding a source affects only later claims.

  A THREAD route is recorded only for a story whose stage row is at `queued` at the claim,
  the stage a placement claims from too. Anything else cannot merge in thread mode however
  it is claimed: the merge gate's Gate A refuses a story no triage recorded, and a row
  anywhere past `queued` belongs to a claim already in flight. Such a claim records a `pr`
  route, which binds its base branch and nothing else.

  ## The stage, moved by control

  `queued -> claimed` is a control transition: it is chained, and a runner may not report it
  (`StageMachine.runner_transitions/0`). `enter_claimed/3` makes it for an interactive thread
  claim, AFTER the claim commits, because `Stages.advance/4` reads the story under its own
  lock on another connection. It is idempotent, so the claimant's first stage report makes it
  again when a claim's own attempt did not land (a bulk claim never attempts it), and from
  `claimed` on the claimant reports its stages as a runner would
  (`LoopctlWeb.StoryStageReportController`).
  """

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ClaimRoute
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake
  alias Loopctl.WorkBreakdown.Story

  # THE thread branch namespace, fixed by the Epic 45 PRD: a thread's branch is
  # `loop/<story-id>`, the `loop/**` rulesets and the CI triggers are written for it, and a
  # runner's thread branch is cut the same way. Not a runner's declared prefix: that is a
  # constraint on what one machine pushes, read live from whichever runners are connected, and
  # an interactive claim is no runner's.
  @thread_prefix "loop/"

  @doc """
  Records the route of `story`'s new claim, inside the claim's transaction. `stage_row` is
  the row `Stages.follow_claim/4` returned (nil when the story has none).

  Returns `{:ok, %ClaimRoute{}}`, or `{:ok, nil}` when the project has no single live intake
  source.
  """
  @spec record_route(Ecto.UUID.t(), Story.t(), StoryStage.t() | nil) ::
          {:ok, ClaimRoute.t() | nil} | {:error, term()}
  def record_route(tenant_id, %Story{} = story, stage_row),
    do:
      record_route(
        tenant_id,
        story,
        stage_row,
        Intake.source_for_project(tenant_id, story.project_id)
      )

  @doc """
  `record_route/3` with the project's source already resolved, for a caller that resolves
  every project of a batch in one read under its locks (`sources_by_project/2`).
  """
  @spec record_route(
          Ecto.UUID.t(),
          Story.t(),
          StoryStage.t() | nil,
          {:ok, term()} | {:error, term()}
        ) ::
          {:ok, ClaimRoute.t() | nil} | {:error, term()}
  def record_route(tenant_id, %Story{} = story, stage_row, source_result) do
    unless AdminRepo.in_transaction?(),
      do: raise(ArgumentError, "record_route/4 runs inside the claiming transaction")

    case source_result do
      {:ok, source} -> insert(tenant_id, story, route_for(source, story, stage_row))
      {:error, _no_single_source} -> {:ok, nil}
    end
  end

  @doc """
  Each of `project_ids`' single live intake source, in ONE read, as
  `Intake.source_for_project/2` would answer it for each.
  """
  @spec sources_by_project(Ecto.UUID.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => term()}
  def sources_by_project(tenant_id, project_ids) do
    import Ecto.Query

    ids = Enum.uniq(project_ids)

    sources =
      tenant_id
      |> Intake.live_sources_query()
      |> where([s], s.project_id in ^ids)
      |> AdminRepo.all()

    Map.new(ids, &{&1, Intake.select_project_source(sources, &1)})
  end

  defp route_for(%{mode: :thread} = source, story, %StoryStage{stage: :queued}) do
    case DispatchPayload.branch_for(story, [@thread_prefix]) do
      {:ok, branch} ->
        %{mode: "thread", base_branch: source.base_branch, branch: branch}

      {:error, reason} ->
        # Not silent: the claim stands as a pr claim, and the log says why it is not a thread.
        Logger.warning(
          "interactive claim of #{story.id} records a pr route: no thread branch " <>
            "(#{inspect(reason)})"
        )

        pr_route(source)
    end
  end

  defp route_for(source, _story, _stage_row), do: pr_route(source)

  defp pr_route(source), do: %{mode: "pr", base_branch: source.base_branch, branch: nil}

  defp insert(tenant_id, story, route) do
    # AN UPSERT on the claim's own key: the claim being made now defines its route. A row at
    # this epoch can only be a leftover (a restore that replayed epochs), and refusing the claim
    # over it would abort the claim's whole transaction, a bulk claim's batch included.
    %ClaimRoute{
      tenant_id: tenant_id,
      story_id: story.id,
      claim_epoch: story.claim_epoch,
      mode: route.mode,
      base_branch: route.base_branch,
      branch: route.branch
    }
    |> AdminRepo.insert(
      on_conflict: {:replace, [:mode, :base_branch, :branch]},
      conflict_target: [:tenant_id, :story_id, :claim_epoch],
      returning: true
    )
  end

  @doc """
  Moves an interactive THREAD claim's stage row `queued -> claimed`, once the claim has
  committed. Idempotent: a row already at `claimed` under this epoch answers `{:ok, row}`.

  `opts`: `:actor_label`, `:actor_role` and `:actor_lineage`, resolved by the caller from the
  claiming key, as `Stages.advance/4` requires of a chained transition.
  """
  @spec enter_claimed(Ecto.UUID.t(), Story.t(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, term()}
  def enter_claimed(tenant_id, %Story{} = story, opts) do
    case Stages.get(tenant_id, story.id) do
      %StoryStage{stage: :claimed, claim_epoch: epoch} = row when epoch == story.claim_epoch ->
        {:ok, row}

      _other ->
        Stages.advance(tenant_id, story.id, {:queued, :claimed},
          claim_epoch: story.claim_epoch,
          actor_label: Keyword.get(opts, :actor_label),
          actor_role: Keyword.fetch!(opts, :actor_role),
          # FETCHED, never defaulted: `Stages.advance/4` refuses a chained transition whose
          # caller did not state a lineage, and a default here would turn a caller that forgot
          # to resolve one into an attested empty lineage on the chain.
          actor_lineage: Keyword.fetch!(opts, :actor_lineage)
        )
    end
  end

  @doc """
  The interactive route of `story`'s CURRENT claim, or nil: a placed claim, and a claim made
  before routes were recorded, have none.
  """
  @spec current_route(Ecto.UUID.t(), Story.t()) :: ClaimRoute.t() | nil
  def current_route(tenant_id, %Story{} = story) do
    import Ecto.Query

    AdminRepo.one(
      from r in ClaimRoute,
        where:
          r.tenant_id == ^tenant_id and r.story_id == ^story.id and
            r.claim_epoch == ^story.claim_epoch
    )
  end
end
