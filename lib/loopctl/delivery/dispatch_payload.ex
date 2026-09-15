defmodule Loopctl.Delivery.DispatchPayload do
  @moduledoc """
  The fields of a dispatch that loopctl KNOWS, filled in from its own records (#803, #850).

  `RunnerDispatch` requires `repo`, `branch`, `base_branch`, `wall_clock_seconds` and
  `max_turns`, and `cast_dispatch/1` applies no defaults — so a caller that omits one is
  refused. That refusal is expensive and arrives late: `Runners.dispatch/3` casts the payload
  as its FIRST step, which runs after `Placement.place/4` has minted a session dispatch,
  claimed the story and appended `dispatch_created` and `story_stage_claimed` to the immutable
  audit chain. A missing field therefore costs two permanent chain entries, an ephemeral key,
  and a claim taken and released, per attempt.

  Every one of those five is something loopctl can look up:

  - `repo` and `base_branch` are the story's project's intake SOURCE — the row that binds a
    project to a repository, and where an operator sets `main` for a repository that uses it;
  - `branch` is derived from the story, so two stories never share one;
  - the budgets are the operator's configured policy, which is where a cost decision belongs.

  So an operator names a story and a runner, and nothing else. This is the same derivation
  `Loopctl.Delivery.DispatchDriver` makes for an unattended placement — one module, so the
  branch an operator's dispatch lands on and the one the driver would have chosen are the
  same name.

  ## What it will NOT fill in

  A caller's own value always wins: a deliberate `branch` or a smaller `max_turns` passes
  through untouched. What no caller may supply is the `story` object, which
  `Placement.place/4` refuses outright — loopctl builds that from the story row, because a
  control plane able to hand a runner prose is able to run anything on that machine.
  """

  import Ecto.Query

  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  @type error ::
          :story_not_found
          | {:no_intake_source, Ecto.UUID.t()}
          | {:ambiguous_intake_source, Ecto.UUID.t(), pos_integer()}
          | {:unset, atom()}
          | {:over_contract_maximum, atom()}

  @doc """
  Fills the dispatch fields `dispatch` does not carry, from the story's own records.

  Returns the payload with string keys, ready for `Placement.place/4`. `{:error, reason}` when
  a field cannot be derived and the caller did not supply it — a project bound to no intake
  source, or a budget the operator has not set — which is a refusal BEFORE anything is minted
  rather than after.

  `kind` decides which budgets are read: an `implement` session and a `triage` session are
  different pieces of work with different costs, and the operator sets them separately.
  """
  @spec fill(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, error()}
  def fill(tenant_id, %{} = dispatch) when is_binary(tenant_id) do
    story_id = Map.get(dispatch, "story_id")
    kind = Map.get(dispatch, "kind", "implement")

    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, dispatch} <- fill_repo(tenant_id, story, dispatch),
         {:ok, dispatch} <- fill_budgets(kind, dispatch) do
      {:ok, put_new(dispatch, "branch", branch_for(story))}
    end
  end

  @doc """
  The branch a story's session works on: its number, and eight characters of its id.

  The id is in it because a story NUMBER is unique only within its project, and two projects
  may hold intake sources naming the same repository — nothing forbids it. Without the suffix
  two different stories dispatched to one repository could be given one branch, and the second
  session would find the first's work already there.
  """
  @spec branch_for(Story.t()) :: String.t()
  def branch_for(%Story{} = story),
    do: "feature/story-#{story.number}-#{String.slice(story.id, 0, 8)}"

  defp fill_repo(tenant_id, story, dispatch) do
    if Map.has_key?(dispatch, "repo") and Map.has_key?(dispatch, "base_branch") do
      {:ok, dispatch}
    else
      with {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id) do
        {:ok,
         dispatch
         |> put_new("repo", source.repo_full_name)
         |> put_new("base_branch", source.base_branch)}
      end
    end
  end

  # ONE READ OF THE OPERATOR'S POLICY, and the same reader the unattended driver uses, so an
  # operator's placement and the driver's cannot disagree about what a session may spend.
  defp fill_budgets(kind, dispatch) do
    if Map.has_key?(dispatch, "wall_clock_seconds") and Map.has_key?(dispatch, "max_turns") do
      {:ok, dispatch}
    else
      {clock_key, turns_key} = budget_keys(kind)

      with {:ok, seconds} <- budget(clock_key),
           {:ok, turns} <- budget(turns_key) do
        {:ok,
         dispatch
         |> put_new("wall_clock_seconds", seconds)
         |> put_new("max_turns", turns)}
      end
    end
  end

  defp budget_keys("triage"), do: {:triage_wall_clock_seconds, :triage_max_turns}
  defp budget_keys(_implement), do: {:dispatch_wall_clock_seconds, :dispatch_max_turns}

  defp budget(key), do: DispatchDriver.normalise_budget(Application.get_env(:loopctl, key), key)

  defp fetch_story(tenant_id, story_id) when is_binary(story_id) do
    {:ok, story} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)
      end)

    if story, do: {:ok, story}, else: {:error, :story_not_found}
  end

  defp fetch_story(_tenant_id, _story_id), do: {:error, :story_not_found}

  defp put_new(dispatch, key, value) do
    if Map.has_key?(dispatch, key), do: dispatch, else: Map.put(dispatch, key, value)
  end
end
