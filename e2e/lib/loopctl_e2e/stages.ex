defmodule LoopctlE2e.Stages do
  @moduledoc """
  The ordered stages one issue passes through the factory (AC-52.9.4), each a read and a
  predicate, and the leftover checks run after `done` (AC-52.9.5).

  A check returns `{:done, ctx}` (the stage is reached; `ctx` may carry what later stages
  need), `{:wait, last_state}` (not yet; `last_state` is what the run reports if the budget
  passes) or `{:fail, last_state}` (the story left the main line, so waiting cannot help).

  Every read is an existing one: the story list filtered by issue number, the story's stage
  row, the escalation inbox, and GitHub's pulls, check runs, reviews, deployments and issues.
  The factory's state is read, never written (US-52.9 failure_modes.state).

  Stage names follow `Loopctl.Delivery.StageMachine`'s main line. `review_recorded` reads the
  PR's reviews, or the stage reaching `merged`: loopctl has no read for review records, and
  its merge gate refuses a head no verifier judged, so a merged story was reviewed.
  """

  alias LoopctlE2e.Client

  @main_line ~w(detected triaged queued claimed worktree implementing reviewing pr_open ci
                merged deployed verified done)

  @off_line ~w(escalated failed)

  @minute 60_000

  @type ctx :: map()
  @type outcome :: {:done, ctx()} | {:wait, String.t()} | {:fail, String.t()}
  @type stage :: %{
          name: atom(),
          budget_ms: pos_integer(),
          check: (Client.t(), ctx() -> outcome())
        }

  @doc "The stages in order, each with its budget inside the run's 120 minutes."
  @spec all() :: [stage()]
  def all do
    [
      stage(:story_created, 10, &story_created/2),
      stage(:triaged, 10, &at_least(&1, &2, "triaged")),
      stage(:dispatched, 15, &at_least(&1, &2, "claimed")),
      stage(:pr_opened, 30, &pr_opened/2),
      stage(:ci_green, 20, &ci_green/2),
      stage(:review_recorded, 15, &review_recorded/2),
      stage(:merged, 10, &merged/2),
      stage(:deployed, 10, &deployed/2),
      stage(:issue_closed, 10, &issue_closed/2),
      stage(:done, 10, &at_least(&1, &2, "done"))
    ]
  end

  defp stage(name, minutes, check), do: %{name: name, budget_ms: minutes * @minute, check: check}

  @doc "The branch suffix loopctl derives for a story (`DispatchPayload.story_suffix/1`)."
  @spec branch_suffix(map()) :: String.t()
  def branch_suffix(%{"number" => number, "id" => id}),
    do: "story-#{number}-#{String.slice(id, 0, 8)}"

  # --- stages ---

  defp story_created(client, ctx) do
    params = [project_id: ctx.project_id, issue_number: ctx.issue_number]

    case Client.get(client, :loopctl, "/api/v1/stories", params) do
      {:ok, 200, %{"data" => [story | _]}} -> {:done, Map.put(ctx, :story, story)}
      other -> {:wait, "no story for issue ##{ctx.issue_number}: #{describe(other)}"}
    end
  end

  defp at_least(client, ctx, wanted) do
    case stage_row(client, ctx) do
      {:ok, %{"stage" => stage} = row} when stage in @off_line ->
        {:fail, "stage #{stage}: #{inspect(row["escalation_reason"])}"}

      {:ok, %{"stage" => stage}} ->
        if index(stage) >= index(wanted),
          do: {:done, Map.put(ctx, :stage, stage)},
          else: {:wait, "stage #{stage}"}

      {:error, why} ->
        {:wait, why}
    end
  end

  defp pr_opened(client, ctx) do
    suffix = branch_suffix(ctx.story)

    with {:ok, 200, pulls} when is_list(pulls) <-
           Client.get(client, :github, "/repos/#{ctx.repo}/pulls", state: "all", per_page: 100),
         %{"number" => number} <- Enum.find(pulls, &head_ends_with?(&1, suffix)) do
      {:done, Map.put(ctx, :pr, number)}
    else
      nil -> {:wait, "no PR whose head branch ends with #{suffix}"}
      other -> {:wait, describe(other)}
    end
  end

  defp ci_green(client, ctx) do
    with {:ok, %{"head" => %{"sha" => sha}}} <- pull(client, ctx),
         {:ok, 200, %{"check_runs" => [_ | _] = runs}} <-
           Client.get(client, :github, "/repos/#{ctx.repo}/commits/#{sha}/check-runs",
             per_page: 100
           ) do
      judge_checks(runs, ctx)
    else
      {:ok, 200, %{"check_runs" => []}} -> {:wait, "no check runs yet"}
      other -> {:wait, describe(other)}
    end
  end

  defp judge_checks(runs, ctx) do
    failed =
      Enum.filter(runs, &(&1["conclusion"] in ~w(failure cancelled timed_out action_required)))

    pending = Enum.reject(runs, &(&1["status"] == "completed"))

    cond do
      failed != [] -> {:fail, "checks failed: #{names(failed)}"}
      pending != [] -> {:wait, "checks running: #{names(pending)}"}
      true -> {:done, ctx}
    end
  end

  defp review_recorded(client, ctx) do
    case Client.get(client, :github, "/repos/#{ctx.repo}/pulls/#{ctx.pr}/reviews") do
      {:ok, 200, [_ | _]} -> {:done, ctx}
      {:ok, 200, []} -> merged_means_reviewed(client, ctx)
      other -> {:wait, describe(other)}
    end
  end

  defp merged_means_reviewed(client, ctx) do
    case at_least(client, ctx, "merged") do
      {:done, _} -> {:done, ctx}
      {:wait, state} -> {:wait, "no review on PR ##{ctx.pr}; #{state}"}
      fail -> fail
    end
  end

  defp merged(client, ctx) do
    case pull(client, ctx) do
      {:ok, %{"merged" => true, "merge_commit_sha" => sha}} ->
        {:done, Map.put(ctx, :merge_sha, sha)}

      {:ok, %{"state" => "closed"}} ->
        {:fail, "PR ##{ctx.pr} closed without merging"}

      {:ok, %{"state" => state}} ->
        {:wait, "PR ##{ctx.pr} #{state}"}

      other ->
        {:wait, describe(other)}
    end
  end

  defp deployed(client, ctx) do
    path = "/repos/#{ctx.repo}/deployments"

    with {:ok, 200, [%{"id" => id} | _]} <-
           Client.get(client, :github, path, sha: ctx.merge_sha, environment: "production"),
         {:ok, 200, [%{"state" => state} | _]} <-
           Client.get(client, :github, "#{path}/#{id}/statuses") do
      if state == "success",
        do: {:done, ctx},
        else: {:wait, "deployment #{id} is #{state}"}
    else
      {:ok, 200, []} -> {:wait, "no production deployment of #{ctx.merge_sha}"}
      other -> {:wait, describe(other)}
    end
  end

  defp issue_closed(client, ctx) do
    case Client.get(client, :github, "/repos/#{ctx.repo}/issues/#{ctx.issue_number}") do
      {:ok, 200, %{"state" => "closed", "labels" => labels}} ->
        if Enum.any?(labels, &resolution_label?/1),
          do: {:done, ctx},
          else: {:wait, "issue closed without a loopctl:resolution-* label"}

      {:ok, 200, %{"state" => state}} ->
        {:wait, "issue #{state}"}

      other ->
        {:wait, describe(other)}
    end
  end

  # --- leftovers (AC-52.9.5) ---

  @doc """
  What is still open for the run's story after `done`, one line each; `[]` is clean.
  A read that fails is itself a leftover, because an unread check proves nothing.
  """
  @spec leftovers(Client.t(), ctx()) :: [String.t()]
  def leftovers(client, ctx) do
    [&in_flight/2, &escalated/2, &open_pr/2, &open_issue/2]
    |> Enum.flat_map(& &1.(client, ctx))
  end

  defp in_flight(client, ctx) do
    case stage_row(client, ctx) do
      {:ok, %{"stage" => "done"}} -> []
      {:ok, %{"stage" => stage}} -> ["story is at #{stage}, so a dispatch may be in flight"]
      {:error, why} -> ["story stage unread: #{why}"]
    end
  end

  defp escalated(client, ctx) do
    case Client.get(client, :loopctl, "/api/v1/escalations", project_id: ctx.project_id) do
      {:ok, 200, %{"data" => rows}} ->
        for %{"story_id" => id} <- rows,
            id == ctx.story["id"],
            do: "escalation open for the story"

      other ->
        ["escalation list unread: #{describe(other)}"]
    end
  end

  defp open_pr(client, ctx) do
    suffix = branch_suffix(ctx.story)

    case Client.get(client, :github, "/repos/#{ctx.repo}/pulls", state: "open", per_page: 100) do
      {:ok, 200, pulls} when is_list(pulls) ->
        for pr <- pulls, head_ends_with?(pr, suffix), do: "PR ##{pr["number"]} is still open"

      other ->
        ["open PRs unread: #{describe(other)}"]
    end
  end

  defp open_issue(client, ctx) do
    case Client.get(client, :github, "/repos/#{ctx.repo}/issues/#{ctx.issue_number}") do
      {:ok, 200, %{"state" => "closed"}} -> []
      {:ok, 200, %{"state" => state}} -> ["issue ##{ctx.issue_number} is #{state}"]
      other -> ["issue unread: #{describe(other)}"]
    end
  end

  # --- reads ---

  defp stage_row(client, ctx) do
    case Client.get(client, :loopctl, "/api/v1/stories/#{ctx.story["id"]}/stage") do
      {:ok, 200, %{"stage" => %{} = row}} -> {:ok, row}
      {:ok, 200, %{"stage" => nil}} -> {:error, "no stage row yet"}
      other -> {:error, describe(other)}
    end
  end

  defp pull(client, ctx) do
    case Client.get(client, :github, "/repos/#{ctx.repo}/pulls/#{ctx.pr}") do
      {:ok, 200, %{} = pr} -> {:ok, pr}
      other -> {:error, describe(other)}
    end
  end

  defp head_ends_with?(%{"head" => %{"ref" => ref}}, suffix) when is_binary(ref),
    do: String.ends_with?(ref, suffix)

  defp head_ends_with?(_pr, _suffix), do: false

  defp resolution_label?(%{"name" => "loopctl:resolution-" <> _}), do: true
  defp resolution_label?(_label), do: false

  defp index(stage), do: Enum.find_index(@main_line, &(&1 == stage)) || -1

  defp names(runs), do: Enum.map_join(runs, ", ", & &1["name"])

  defp describe({:ok, status, body}), do: "HTTP #{status} #{inspect(body, limit: 5)}"
  defp describe({:error, why}) when is_binary(why), do: why
  defp describe(other), do: inspect(other, limit: 5)
end
