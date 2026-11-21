defmodule LoopctlRunner.Forge do
  @moduledoc """
  The runner's one read of the forge (US-48.16): the pull requests of a dispatch's branch into its
  base, asked of GitHub with the `gh` CLI the session already uses — no new credential.

  `pull_requests/5` is the default of `LoopctlRunner.Control`'s `:forge` option, a function of
  `(repo, head, base, timeout_ms)`; a test passes its own, so the suite never reaches GitHub. What
  the answer means is `LoopctlRunner.PrStages`'s to say, not this module's.

  The command, exactly:

      gh pr list --repo <owner/name> --head <branch> --base <base> --state all --limit 5
        --json number,state,headRefName,headRefOid,baseRefName,isCrossRepository,mergeCommit,
               mergedAt,statusCheckRollup

  It runs as the runner's own command (`LoopctlRunner.ProcessGroup.run/5`): bounded by
  `timeout_ms` and its whole group killed past it, the credential scrub applied, and only the
  forge tokens `gh` authenticates with (`GH_TOKEN`, `GITHUB_TOKEN`) inherited, as the runner's own
  base fetch inherits them. `GH_PROMPT_DISABLED` is set because nobody is there to answer a
  prompt. Without a token in the environment `gh` reads its own login (`gh auth login`).

  ## The merge loopctl instructs (US-48.17)

  Two more commands, run the same way, serve `LoopctlRunner.MergeRun` — the runner merging a
  pull request because loopctl's merge gate allowed its head, never on its own judgement:

      gh pr view <number> --repo <owner/name>
        --json number,state,headRefName,headRefOid,baseRefName,isCrossRepository,mergeCommit,
               body,closingIssuesReferences

      gh pr edit <number> --repo <owner/name> --body <body>

      gh pr merge <number> --repo <owner/name> --squash --match-head-commit <head_sha>
        --body <body>

  The edit and the explicit squash body carry the pull request's text with its issue-closing
  keywords rewritten (`LoopctlRunner.ClosingKeywords`), so the merge closes no issue: loopctl
  closes the one a story came from, with its resolution label on first.

  The merge names the head, so GitHub refuses it when the head is no longer the one the gate
  allowed. There is no `--admin` (it would bypass the branch protection the gate does not
  replace), no `--auto` (a later push would be merged unjudged) and no `--delete-branch` (gh
  deletes the LOCAL branch too, and the branch and its worktree are the runner's teardown's).
  `pull_request/4`, `edit_body/5` and `merge/6` are the defaults of `LoopctlRunner.Control`'s `:merge_forge`
  option; a test passes its own.
  """

  alias LoopctlRunner.ProcessGroup

  @fields ~w(number state headRefName headRefOid baseRefName isCrossRepository mergeCommit
             mergedAt statusCheckRollup)

  # A branch has one pull request in the ordinary case; a few more covers a closed attempt and
  # its retry without fetching a history.
  @limit 5

  @inherit ~w(GH_TOKEN GITHUB_TOKEN)
  @env [{"GH_PROMPT_DISABLED", "1"}, {"GH_NO_UPDATE_NOTIFIER", "1"}, {"NO_COLOR", "1"}]

  # The service's PATH is what its unit or plist declares, not a login shell's (see
  # `LoopctlRunner.Health`): `gh` is found on PATH first, then where its installers put it.
  @standard_paths ~w(/usr/local/bin/gh /opt/homebrew/bin/gh /usr/bin/gh)

  # How much of a failing gh's output a reason carries.
  @max_output 300

  @doc """
  The decoded `gh pr list` answer for `head` into `base` in `repo` (`owner/name`): `{:ok, list}`,
  or `{:error, reason}` when gh is missing, fails, answers something that is not a JSON list, or
  does not answer within `timeout_ms`. `gh` is the executable to run, found as above when nil.
  """
  @spec pull_requests(String.t(), String.t(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, list()} | {:error, String.t()}
  def pull_requests(repo, head, base, timeout_ms, gh \\ nil) do
    with {:ok, path} <- locate(gh), do: run(path, args(repo, head, base), timeout_ms)
  end

  @doc "The `gh` argv `pull_requests/5` runs."
  @spec args(String.t(), String.t(), String.t()) :: [String.t()]
  def args(repo, head, base) do
    ["pr", "list", "--repo", repo, "--head", head, "--base", base] ++
      ["--state", "all", "--limit", Integer.to_string(@limit), "--json", Enum.join(@fields, ",")]
  end

  @view_fields ~w(number state headRefName headRefOid baseRefName isCrossRepository mergeCommit
                  body closingIssuesReferences)

  @doc """
  The decoded `gh pr view` answer for pull request `number` of `repo`: `{:ok, map}`, or
  `{:error, reason}` when gh is missing, fails, answers something that is not a JSON object, or
  does not answer within `timeout_ms`.
  """
  @spec pull_request(String.t(), pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def pull_request(repo, number, timeout_ms, gh \\ nil) do
    with {:ok, path} <- locate(gh),
         {:ok, out} <- run_ok(path, view_args(repo, number), timeout_ms) do
      case JSON.decode(out) do
        {:ok, pr} when is_map(pr) -> {:ok, pr}
        _ -> {:error, "gh answered something that is not a JSON object: #{excerpt(out)}"}
      end
    end
  end

  @doc "The `gh` argv `pull_request/4` runs."
  @spec view_args(String.t(), pos_integer()) :: [String.t()]
  def view_args(repo, number),
    do: [
      "pr",
      "view",
      Integer.to_string(number),
      "--repo",
      repo,
      "--json",
      Enum.join(@view_fields, ",")
    ]

  @doc """
  Replaces pull request `number`'s body with `body`: `:ok`, or `{:error, reason}` when gh is
  missing, fails, or does not answer within `timeout_ms`.
  """
  @spec edit_body(String.t(), pos_integer(), String.t(), pos_integer(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def edit_body(repo, number, body, timeout_ms, gh \\ nil) do
    with {:ok, path} <- locate(gh),
         {:ok, _out} <- run_ok(path, edit_args(repo, number, body), timeout_ms),
         do: :ok
  end

  @doc "The `gh` argv `edit_body/5` runs."
  @spec edit_args(String.t(), pos_integer(), String.t()) :: [String.t()]
  def edit_args(repo, number, body),
    do: ["pr", "edit", Integer.to_string(number), "--repo", repo, "--body", body]

  @doc """
  Squash-merges pull request `number` of `repo` at exactly `head_sha`, with `body` as the squash
  commit's message body: `:ok` when gh exits 0,
  `{:refused, output}` when it exits non-zero (GitHub, or gh, said no — a moved head among the
  reasons), `{:error, reason}` when gh is missing or does not answer within `timeout_ms`, which
  says nothing about whether the merge happened.
  """
  @spec merge(String.t(), pos_integer(), String.t(), String.t(), pos_integer(), String.t() | nil) ::
          :ok | {:refused, String.t()} | {:error, String.t()}
  def merge(repo, number, head_sha, body, timeout_ms, gh \\ nil) do
    with {:ok, path} <- locate(gh) do
      case ProcessGroup.run(path, merge_args(repo, number, head_sha, body), timeout_ms, @env,
             inherit: @inherit
           ) do
        {:ok, _out, 0} -> :ok
        {:ok, out, status} -> {:refused, "gh exited #{status}: #{excerpt(out)}"}
        {:error, :timeout} -> {:error, "gh did not answer within #{timeout_ms} ms"}
      end
    end
  end

  @doc "The `gh` argv `merge/6` runs."
  @spec merge_args(String.t(), pos_integer(), String.t(), String.t()) :: [String.t()]
  def merge_args(repo, number, head_sha, body),
    do: [
      "pr",
      "merge",
      Integer.to_string(number),
      "--repo",
      repo,
      "--squash",
      "--match-head-commit",
      head_sha,
      "--body",
      body
    ]

  defp locate(gh) do
    case gh || executable() do
      path when is_binary(path) ->
        if File.regular?(path),
          do: {:ok, path},
          else: {:error, "gh is not installed at #{path}"}

      nil ->
        {:error, "gh is not installed on this runner's PATH"}
    end
  end

  defp run_ok(gh, args, timeout_ms) do
    case ProcessGroup.run(gh, args, timeout_ms, @env, inherit: @inherit) do
      {:ok, out, 0} -> {:ok, out}
      {:ok, out, status} -> {:error, "gh exited #{status}: #{excerpt(out)}"}
      {:error, :timeout} -> {:error, "gh did not answer within #{timeout_ms} ms"}
    end
  end

  defp run(gh, args, timeout_ms) do
    with {:ok, out} <- run_ok(gh, args, timeout_ms) do
      case JSON.decode(out) do
        {:ok, prs} when is_list(prs) -> {:ok, prs}
        _ -> {:error, "gh answered something that is not a JSON list: #{excerpt(out)}"}
      end
    end
  end

  defp excerpt(out), do: out |> String.trim() |> String.slice(0, @max_output)

  defp executable,
    do: System.find_executable("gh") || Enum.find(@standard_paths, &File.regular?/1)
end
