defmodule Loopctl.Verification.GitHubActions do
  @moduledoc """
  US-26.4.3, redesigned by US-26.4.6 — story verification's CI adapter, over GitHub Actions.

  It judges a commit by EXACTLY the merge gate's rules, through the merge gate's own code, so a
  verification run means what a merge decision means (issue #913):

  1. `check_change/1` compares the change with the story's base branch (`compare/3`). An EMPTY
     three-dot diff is refused `empty_change`, the merge gate's own code for the same shape:
     nothing shows the story's work is in the commit, which is what an old green commit of the
     base, or an empty commit on top of one, looks like. A commit that edits its own CI
     definitions is refused `ci_definition_changed` — or `ci_definition_unknown` when that
     cannot be told — by `Loopctl.Delivery.CiDefinition.reasons/1`, the rule the merge gate
     refuses by. The worker asks this once per run, and not at all for a commit the thread
     merge gate allowed, which it already compared
  2. `verdict/1` reads the evidence, `check_evidence/3` for the story's branch and the commit:
     the jobs of PUSH runs of that branch at that SHA, never another branch's runs, a fork's
     `pull_request` run or a `workflow_dispatch`. Anything else is something the implementer
     can produce itself (`Loopctl.Delivery.CiEvidence`)
  3. the verdict is `CiEvidence.judge/2` over the intake source's `required_checks`

  Every read goes through `Loopctl.Delivery.PullRequestSource.impl/0` — the same adapter, the
  same timeouts, and the same classification of what a failure means. `transient?/1` and
  `retry_after/1` of `Loopctl.Delivery.MergePrecondition` decide wait versus final; this
  module turns that into `Loopctl.Verification.CiBehaviour`'s declared outcomes, so the worker
  never sees a GitHub error term.

  ## Reason codes

  A fixed set of strings with no numbers in them, so none reads as an HTTP status:
  `empty_change`, `ci_definition_changed`, `ci_definition_unknown`, `no_required_checks`,
  `credential_unavailable`, `unresolved_sha` and `repository_unreadable` (resolving an
  abbreviated SHA: a 422, which GitHub answers for an unknown prefix and an ambiguous one
  alike, and a 404, a repository missing or unreadable), `forge_unauthorized` (401), `forge_forbidden` (a 403 that is not a
  rate limit), `forge_not_found` (404), `forge_unprocessable` (422), `forge_rejected` (any
  other status that is not transient), `too_many_workflow_runs`, `workflow_runs_truncated`,
  `jobs_truncated`, `invalid_repository`, `invalid_ref` and `forge_unreadable`.

  ## Evidence URLs

  Built from the repository name and the numeric run and job ids, never echoed from the
  forge's response, so every recorded URL is inside the tenant's own intake-source
  repository.
  """

  @behaviour Loopctl.Verification.CiBehaviour

  alias Loopctl.Delivery.CiDefinition
  alias Loopctl.Delivery.CiEvidence
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Verification.Credential

  @impl true
  def resolve_commit(repo, sha, %Credential{kind: :operator_token}) do
    case source().resolve_commit(repo, sha) do
      {:ok, full} -> {:ok, full}
      {:error, reason} -> classify(reason, :resolve)
    end
  end

  def resolve_commit(_repo, _sha, _credential), do: {:refused, "credential_unavailable"}

  @impl true
  def check_change(%{credential: %Credential{kind: :operator_token}} = request) do
    with {:ok, comparison} <-
           read(source().compare(request.repo, request.base_branch, request.sha)) do
      change(comparison)
    end
  end

  def check_change(_request), do: {:refused, "credential_unavailable"}

  @impl true
  def verdict(%{credential: %Credential{kind: :operator_token}} = request) do
    if CiEvidence.lookup_names(request.required_checks) == [] do
      # The worker refuses this before asking; refused here too, so the adapter can never
      # judge an empty list — over which every check "passed".
      {:refused, "no_required_checks"}
    else
      with {:ok, evidence} <-
             read(source().check_evidence(request.repo, request.sha, request.branch)) do
        judge(request, evidence)
      end
    end
  end

  def verdict(_request), do: {:refused, "credential_unavailable"}

  # An empty three-dot diff is refused, never judged: nothing shows the story's work is in the
  # commit. It is what the base's own old green commit looks like, and an empty commit on top
  # of one — whose merge base is not itself, so only the diff tells.
  defp change(%{diffstat: %{files: 0}}), do: {:refused, "empty_change"}

  defp change(comparison) do
    case CiDefinition.reasons(Map.get(comparison, :diff)) do
      [] -> :ok
      [{:ci_definition_changed, _names} | _rest] -> {:refused, "ci_definition_changed"}
      [{:ci_definition_unknown, _reason} | _rest] -> {:refused, "ci_definition_unknown"}
    end
  end

  defp judge(request, evidence) do
    result = CiEvidence.judge(request.required_checks, evidence)
    counted = CiEvidence.counted(evidence)

    cond do
      result.failed != [] ->
        [{name, why} | _rest] = result.failed

        {:fail,
         %{url: failing_url(request.repo, name, why, counted), check: name, conclusion: why}}

      result.pending != [] or result.missing != [] ->
        {:wait, :ci_pending}

      true ->
        {:pass, %{url: passing_url(request.repo, result.passed, counted)}}
    end
  end

  # The failing JOB, among the jobs the judgement counted. A name that failed because a run
  # DIED with no jobs at all (`run_<conclusion>`) points at a run that failed it that way —
  # never at a jobless run that concluded `success`, which the judgement did not count.
  defp failing_url(repo, name, why, %{jobs: jobs, jobless_runs: jobless}) do
    failed_job =
      Enum.find(jobs, fn job ->
        job.name == name and job.status == "completed" and job.conclusion != "success"
      end)

    dead_run =
      Enum.find(jobless, &(CiEvidence.dead_run?(&1) and CiEvidence.run_conclusion(&1) == why))

    cond do
      failed_job -> job_url(repo, failed_job)
      dead_run -> run_url(repo, Map.get(dead_run, :id))
      true -> actions_url(repo)
    end
  end

  # The judged run: the run of the first required check's job.
  defp passing_url(repo, [name | _rest], %{jobs: jobs}) do
    case Enum.find(jobs, &(&1.name == name)) do
      nil -> actions_url(repo)
      job -> run_url(repo, Map.get(job, :run_id))
    end
  end

  defp passing_url(repo, [], _counted), do: actions_url(repo)

  defp job_url(repo, job) do
    case {Map.get(job, :run_id), Map.get(job, :id)} do
      {run_id, id} when is_integer(run_id) and is_integer(id) ->
        run_url(repo, run_id) <> "/job/#{id}"

      {run_id, _id} ->
        run_url(repo, run_id)
    end
  end

  defp run_url(repo, run_id) when is_integer(run_id), do: actions_url(repo) <> "/runs/#{run_id}"
  defp run_url(repo, _run_id), do: actions_url(repo)

  defp actions_url(repo), do: "https://github.com/#{repo}/actions"

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, reason}), do: classify(reason, :read)

  defp classify(reason, stage) do
    if MergePrecondition.transient?(reason),
      do: {:wait, {:transient, MergePrecondition.retry_after(reason)}},
      else: {:no_verdict, code(reason, stage)}
  end

  # Resolving an abbreviated SHA (AC-26.4.6.7), measured against GitHub on 2026-09-28:
  # `GET /repos/:repo/commits/:ref` answers 422 "No commit found for SHA" for an unknown
  # prefix AND for an unknown full id (it does not tell an ambiguous prefix from an unknown
  # one), and 404 for a repository that is missing or that the token cannot read.
  defp code({:github_api_error, 422}, :resolve), do: "unresolved_sha"
  defp code({:github_api_error, 404}, :resolve), do: "repository_unreadable"
  defp code({:github_api_error, 401}, _stage), do: "forge_unauthorized"
  defp code({:github_api_error, 403}, _stage), do: "forge_forbidden"
  defp code({:github_api_error, 404}, _stage), do: "forge_not_found"
  defp code({:github_api_error, 422}, _stage), do: "forge_unprocessable"
  defp code({:github_api_error, _status}, _stage), do: "forge_rejected"
  defp code({:too_many_workflow_runs, _count}, _stage), do: "too_many_workflow_runs"
  defp code({:workflow_runs_truncated, _total, _read}, _stage), do: "workflow_runs_truncated"
  defp code({:jobs_truncated, _total, _read}, _stage), do: "jobs_truncated"
  defp code({:invalid_repo, _repo}, _stage), do: "invalid_repository"
  defp code({:invalid_ref, _ref}, _stage), do: "invalid_ref"
  defp code(_other, _stage), do: "forge_unreadable"

  defp source, do: PullRequestSource.impl()

  @doc """
  The `Authorization` header for `token`, or none when there is no usable token.

  Takes the VALUE so the rule is unit-testable. A BLANK value is not a token, and used to
  be treated as one: `if token do` is truthy for `""`, so a variable set-but-empty (the
  shape a templated deploy config produces) sent `Authorization: Bearer ` and GitHub 401'd
  every lookup — strictly WORSE than sending nothing, which at least works for a public
  repo. `Loopctl.Delivery.GitHubPullRequestSource` authenticates through it.
  """
  @spec auth_headers(String.t() | nil) :: [{String.t(), String.t()}]
  def auth_headers(token)

  def auth_headers(nil), do: []

  def auth_headers(token) when is_binary(token) do
    case String.trim(token) do
      "" -> []
      trimmed -> [{"authorization", "Bearer #{trimmed}"}]
    end
  end
end
