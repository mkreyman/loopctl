defmodule Loopctl.Verification.CiTarget do
  @moduledoc """
  WHICH repository, branch, base branch, required checks and commit a story's verification
  reads (US-26.4.6), resolved from loopctl's own records only — never from the caller and
  never from the tenant-editable `projects.repo_url`.

  - the REPOSITORY is the story's project's intake source (`Intake.source_for_project/2`),
    the one derivation the merge gate and the dispatcher use. No live source is
    `no_intake_source`, more than one `ambiguous_intake_source`
  - the REQUIRED CHECKS are that source's `required_checks`, in either mode. None (after
    dropping `local-gate`, which is never trusted) is `no_required_checks`: the opt-in
  - the BRANCH is the one the story's placement recorded. For a THREAD it is exactly
    `DispatchPayload.thread_branch/3`, the branch the merge gate judges. Otherwise it is the
    branch the claim's dispatch put on the wire (the pull request's head branch, which the
    runner created), then the branch the runner reported on the stage row; a story with
    neither was never placed on a branch and is `no_story_branch`. The pull request's head
    ref is deliberately not read back from GitHub: a fork's pull request names a branch in
    the FORK, and push runs of a same-named branch in the base repository are not its CI
  - the BASE BRANCH is the one the claim was placed on (`DispatchPayload.placed_base_branch/2`)
  - the MERGE GATE'S ALLOW is the stage row's `merge_gate_allowed_sha` (nil when the gate has
    allowed nothing), and `mode` says how the gate judged it: `:thread` for a claim placed in
    thread mode, which is the one mode where the gate itself refuses an empty change and a
    change to CI definitions; `:pr` otherwise

  Each refusal is `{:unconfigured, code}`: a missing configuration, which reads nothing from
  the forge. A dispatch-route or stage-row read that met database contention is
  `{:wait, :database_busy}`: a wait of its own, because it is loopctl's database and not the
  forge, so it neither counts toward nor ends the worker's forge-fault streak.
  """

  alias Loopctl.Delivery.CiEvidence
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake
  alias Loopctl.WorkBreakdown.Stories

  @type t :: %{
          repo: String.t(),
          branch: String.t(),
          base_branch: String.t(),
          required_checks: [String.t()],
          mode: :pr | :thread,
          merge_gate_allowed_sha: String.t() | nil
        }

  @doc "Reads the facts for `story_id` and resolves them. See the moduledoc."
  @spec gather(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, t()} | {:unconfigured, String.t()} | {:wait, :database_busy}
  def gather(tenant_id, story_id) do
    with {:story, {:ok, story}} <- {:story, Stories.get_story(tenant_id, story_id)},
         {:ok, source} <- source(tenant_id, story),
         {:ok, required} <- required_checks(source),
         {:route, {:ok, route}} <- {:route, DispatchPayload.dispatch_route(tenant_id, story)},
         {:stage, {:ok, stage}} <- {:stage, Stages.fetch(tenant_id, story.id)} do
      resolve(story, source, required, route, stage)
    else
      {:story, {:error, :not_found}} -> {:unconfigured, "story_not_found"}
      {:route, {:error, _busy}} -> {:wait, :database_busy}
      {:stage, {:error, _busy}} -> {:wait, :database_busy}
      {:unconfigured, _code} = refusal -> refusal
    end
  end

  @doc """
  The pure half of `gather/2`: the target, given the story, its source, the required names,
  the claim's dispatch route and the story's stage row (or nil).
  """
  @spec resolve(map(), map(), [String.t()], map(), map() | nil) ::
          {:ok, t()} | {:unconfigured, String.t()}
  def resolve(story, source, required, route, stage) do
    stage_branch = stage && stage.branch

    case story_branch(route, story, stage_branch) do
      {:ok, branch} ->
        {:ok,
         %{
           repo: source.repo_full_name,
           branch: branch,
           base_branch: DispatchPayload.placed_base_branch(route, source),
           required_checks: required,
           mode: if(Map.get(route, :mode) == :thread, do: :thread, else: :pr),
           merge_gate_allowed_sha: stage && stage.merge_gate_allowed_sha
         }}

      :none ->
        {:unconfigured, "no_story_branch"}
    end
  end

  defp source(tenant_id, story) do
    case Intake.source_for_project(tenant_id, story.project_id) do
      {:ok, source} ->
        {:ok, source}

      {:error, {:no_intake_source, _project}} ->
        {:unconfigured, "no_intake_source"}

      {:error, {:ambiguous_intake_source, _project, _n}} ->
        {:unconfigured, "ambiguous_intake_source"}
    end
  end

  defp required_checks(%{required_checks: checks}) when is_list(checks) do
    case CiEvidence.lookup_names(checks) do
      [] -> {:unconfigured, "no_required_checks"}
      names -> {:ok, names}
    end
  end

  defp required_checks(_source), do: {:unconfigured, "no_required_checks"}

  defp story_branch(%{mode: :thread} = route, story, stage_branch) do
    case DispatchPayload.thread_branch(route, story, stage_branch) do
      {:ok, branch} -> {:ok, branch}
      {:error, _reason} -> :none
    end
  end

  defp story_branch(route, _story, stage_branch) do
    case Map.get(route, :branch) || stage_branch do
      branch when is_binary(branch) and branch != "" -> {:ok, branch}
      _none -> :none
    end
  end
end
