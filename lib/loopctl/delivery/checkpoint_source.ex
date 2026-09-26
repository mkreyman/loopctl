defmodule Loopctl.Delivery.CheckpointSource do
  @moduledoc """
  The facts `Loopctl.Delivery.MergePrecondition` judges, built from a THREAD-mode story's
  latest recorded checkpoint instead of a pull request (US-45.4, Epic 45 PRD §3 and §4).

  It returns the same `t:Loopctl.Delivery.PullRequestSource.pull_request/0` map the pull
  request path does, so Gate B, the hard bound, custody and the head comparison run over it
  unchanged, plus the thread facts the gate judges:

  - `:branch_head_sha` — the commit the story's branch names now, or `:missing` when the
    forge has no such branch (a 404). The branch is the one the story was DISPATCHED on
    (`Loopctl.Delivery.DispatchPayload.story_branch/2`), never a name derived here
  - `:pushed?` — `false` when the branch names the checkpoint but the forge cannot find the
    commit (a 404 on `commit/2` or `compare/3`)
  - `:head_tree_sha` — the checkpoint commit's tree AS THE FORGE READS IT. The recorded
    `tree_sha` is the claimant's report; a disagreement is refused rather than believed
  - `:base_tree_sha` — the base branch's tree now. Equal to the checkpoint's, the change is
    `empty_change`: there is nothing to merge, and that is never read as merged

  ## The branch is read FIRST

  A branch that is missing, or names a commit other than the checkpoint, answers WITHOUT the
  commit and comparison reads: the gate sends the story back to `implementing` on that fact
  alone (`branch_missing`, `branch_head_unrecorded`), so nothing else is worth a round trip,
  and a checkpoint that was recorded but never pushed would otherwise 404 on its own sha and
  read as a forge failure a human has to look at. A 404 on the commit or the comparison when
  the branch DOES name the checkpoint is the same fact seen late, and answers `pushed?: false`.

  The reads are SEQUENTIAL: the branch decides whether the other two run at all, and those two
  are bounded by the adapter's timeouts.

  ## Why this is not a second implementation of the behaviour

  `PullRequestSource.pull_request/2` is addressed by a pull request NUMBER, and a thread has
  none: what addresses it is the checkpoint loopctl recorded. So this module composes the
  behaviour's thread reads (`branch_head/2`, `commit/2`, `compare/3`) through the same
  config-resolved forge the pull request path uses — one client, one set of timeouts, one
  failure classification — rather than a second client with its own idea of a 403.

  ## Failure

  Any other read the forge could not answer is `{:error, reason}` for the whole fact, exactly
  as a pull request that could not be read is; `MergePrecondition.transient?/1` decides
  whether that is a retry or an escalation. There is no partial answer that can reach an
  allow.

  ## A checkpoint the executor may have merged

  A `merge_commit_sha` on the checkpoint is NOT proof of a merge: the executor (US-45.5)
  records it BEFORE its compare-and-swap ref update, which can fail. So it is answered as
  merged only when the forge shows that commit reachable from the base branch
  (`PullRequestSource.contains?/3`), and the gate's question is then whether a recorded allow
  authorised it. Not reachable, it is judged as an open checkpoint, never as already merged.
  """

  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Threads.Checkpoint

  @doc """
  The facts of `checkpoint`, in `PullRequestSource.pull_request/0`'s shape plus the thread
  facts listed in the moduledoc. `base_branch` is the intake source's; `branch` is the one
  the story was dispatched on.
  """
  @spec pull_request(String.t(), String.t(), String.t(), Checkpoint.t()) ::
          {:ok, map()} | {:error, term()}
  def pull_request(repo, base_branch, branch, %Checkpoint{merge_commit_sha: merged} = cp)
      when is_binary(merged) do
    case source().contains?(repo, merged, base_branch) do
      {:ok, true} -> {:ok, merged_facts(cp, merged)}
      {:ok, false} -> open_facts(repo, base_branch, branch, cp)
      {:error, _reason} = error -> error
    end
  end

  def pull_request(repo, base_branch, branch, %Checkpoint{} = checkpoint),
    do: open_facts(repo, base_branch, branch, checkpoint)

  defp merged_facts(checkpoint, merged) do
    %{
      state: "closed",
      merged?: true,
      merge_sha: merged,
      head_sha: checkpoint.commit_sha,
      merge_base_sha: checkpoint.commit_sha,
      diffstat: %{files: 0, changed_lines: 0},
      diff: {:ok, %{files: [], renames: []}}
    }
  end

  defp open_facts(repo, base_branch, branch, %Checkpoint{commit_sha: sha}) do
    case branch_head(repo, branch) do
      {:ok, ^sha} -> checkpoint_facts(repo, base_branch, sha)
      {:ok, other} -> {:ok, Map.merge(open(sha), %{branch_head_sha: other})}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_facts(repo, base_branch, sha) do
    with {:ok, commit} <- source().commit(repo, sha),
         {:ok, comparison} <- source().compare(repo, base_branch, sha) do
      {:ok,
       Map.merge(open(sha), %{
         branch_head_sha: sha,
         merge_base_sha: comparison.merge_base_sha,
         diffstat: comparison.diffstat,
         diff: comparison.diff,
         head_tree_sha: commit.tree_sha,
         base_tree_sha: comparison.base_tree_sha
       })}
    else
      {:error, {:github_api_error, 404}} ->
        {:ok, Map.merge(open(sha), %{branch_head_sha: sha, pushed?: false})}

      {:error, _reason} = error ->
        error
    end
  end

  defp open(sha), do: %{state: "open", merged?: false, merge_sha: nil, head_sha: sha}

  # A branch the forge does not have is a FACT about the thread — nothing was pushed, or it
  # was deleted — not a forge failure, so it is `:missing` rather than an error that would
  # escalate. Every other failure keeps its classification.
  defp branch_head(repo, branch) do
    case source().branch_head(repo, branch) do
      {:error, {:github_api_error, 404}} -> {:ok, :missing}
      other -> other
    end
  end

  defp source, do: PullRequestSource.impl()
end
