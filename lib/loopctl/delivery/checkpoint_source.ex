defmodule Loopctl.Delivery.CheckpointSource do
  @moduledoc """
  The facts `Loopctl.Delivery.MergePrecondition` judges, built from a THREAD-mode story's
  latest recorded checkpoint instead of a pull request (US-45.4, Epic 45 PRD §3 and §4).

  It returns the same `t:Loopctl.Delivery.PullRequestSource.pull_request/0` map the pull
  request path does, so Gate B, the hard bound, custody and the head comparison run over it
  unchanged, plus four thread facts the gate adds refusals for:

  - `:branch_head_sha` — the commit the thread branch `loop/<story_id>` names now. The gate
    refuses `branch_head_unrecorded` while it is not the checkpoint: git cannot see a claim,
    so a reclaimed runner can still push, and loopctl never adopts a head nobody reported
  - `:head_tree_sha` — the checkpoint commit's tree AS THE FORGE READS IT. The recorded
    `tree_sha` is the claimant's report; a disagreement is refused rather than believed
  - `:base_tree_sha` — the base branch's tree now. Equal to the checkpoint's, the change is
    `empty_change`: there is nothing to merge, and that is never read as merged
  - `:first_parent_sha` — the checkpoint commit's first parent, which a `base_update`
    checkpoint must have as the checkpoint the gate last allowed

  ## Why this is not a second implementation of the behaviour

  `PullRequestSource.pull_request/2` is addressed by a pull request NUMBER, and a thread has
  none: what addresses it is the checkpoint loopctl recorded. So this module composes the
  behaviour's thread reads (`branch_head/2`, `commit/2`, `compare/3`) through the same
  config-resolved forge the pull request path uses — one client, one set of timeouts, one
  failure classification — rather than a second client with its own idea of a 403.

  ## Failure

  Any read the forge could not answer is `{:error, reason}` for the whole fact, exactly as a
  pull request that could not be read is; `MergePrecondition.transient?/1` decides whether
  that is a retry or an escalation. There is no partial answer that can reach an allow.

  ## A checkpoint the executor already merged

  A `merge_commit_sha` on the checkpoint (US-45.5 writes it) is a merge that happened. It is
  answered without reading anything, as the pull request adapter answers a merged pull
  request: the gate's question is then whether a recorded allow authorised it.
  """

  alias Loopctl.Threads.Checkpoint

  @doc """
  The thread branch a story's checkpoints are pushed to (PRD §4 item 2).
  """
  @spec thread_branch(Ecto.UUID.t()) :: String.t()
  def thread_branch(story_id), do: "loop/" <> story_id

  @doc """
  The facts of `checkpoint`, in `PullRequestSource.pull_request/0`'s shape plus the thread
  facts listed in the moduledoc. `base_branch` is the intake source's.
  """
  @spec pull_request(String.t(), String.t(), Ecto.UUID.t(), Checkpoint.t()) ::
          {:ok, map()} | {:error, term()}
  def pull_request(_repo, _base_branch, _story_id, %Checkpoint{merge_commit_sha: merged} = cp)
      when is_binary(merged) do
    {:ok,
     %{
       state: "closed",
       merged?: true,
       merge_sha: merged,
       head_sha: cp.commit_sha,
       merge_base_sha: cp.commit_sha,
       diffstat: %{files: 0, changed_lines: 0},
       diff: {:ok, %{files: [], renames: []}}
     }}
  end

  def pull_request(repo, base_branch, story_id, %Checkpoint{} = checkpoint) do
    sha = checkpoint.commit_sha

    with {:ok, branch_head} <- source().branch_head(repo, thread_branch(story_id)),
         {:ok, commit} <- source().commit(repo, sha),
         {:ok, comparison} <- source().compare(repo, base_branch, sha) do
      {:ok,
       %{
         state: "open",
         merged?: false,
         merge_sha: nil,
         head_sha: sha,
         merge_base_sha: comparison.merge_base_sha,
         diffstat: comparison.diffstat,
         diff: comparison.diff,
         branch_head_sha: branch_head,
         head_tree_sha: commit.tree_sha,
         base_tree_sha: comparison.base_tree_sha,
         first_parent_sha: List.first(commit.parent_shas)
       }}
    end
  end

  defp source do
    Application.get_env(
      :loopctl,
      :delivery_pull_request_source,
      Loopctl.Delivery.GitHubPullRequestSource
    )
  end
end
