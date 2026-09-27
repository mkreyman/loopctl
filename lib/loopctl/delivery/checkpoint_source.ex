defmodule Loopctl.Delivery.CheckpointSource do
  @moduledoc """
  The facts `Loopctl.Delivery.MergePrecondition` judges, built from a THREAD-mode story's
  latest recorded checkpoint instead of a pull request (US-45.4, Epic 45 PRD §3 and §4).

  It returns the same `t:Loopctl.Delivery.PullRequestSource.pull_request/0` map the pull
  request path does, so Gate B, the hard bound, custody and the head comparison run over it
  unchanged, plus the thread facts the gate judges:

  - `:branch_head_sha` — the commit the story's branch names now, or `:missing` when the
    forge has no such branch: a 404 on the ref in a repository the token CAN read
    (`repository_readable/1`). A 404 because the repository itself cannot be read is a
    token or permission fault, an error a human fixes, never `:missing`. The branch is the
    one the story was DISPATCHED on (`Loopctl.Delivery.DispatchPayload.dispatch_route/2`),
    never a name derived here
  - `:head_tree_sha` — the checkpoint commit's tree AS THE FORGE READS IT. The recorded
    `tree_sha` is the claimant's report; a disagreement is refused rather than believed
  - `:base_tree_sha` — the base branch's tree now. Equal to the checkpoint's, the change is
    `empty_change`: there is nothing to merge, and that is never read as merged
  - `:merge_base_sha` — the comparison's MERGE BASE: the base commit the judged three-dot
    diff is relative to. A thread-mode allow records it as `base_sha`, and the merge executor
    (US-45.5) merges only while the base head still equals it, taking the base-update path
    otherwise. The gate itself judges the diff against that merge base, so a base that moved
    on is not a reason here

  ## The branch is read FIRST

  A branch that is missing, or names a commit other than the checkpoint, answers WITHOUT the
  commit and comparison reads: the gate sends the story back to `implementing` on that fact
  alone (`branch_missing`, `branch_head_unrecorded`), so nothing else is worth a round trip,
  and a checkpoint that was recorded but never pushed would otherwise 404 on its own sha and
  read as a forge failure a human has to look at. Once the branch DOES name the checkpoint,
  the commit is pushed, so a 404 on the commit or the comparison is a wrong base branch or a
  permission fault: an error like any other, which escalates as it does in pr mode.

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
  authorised it. Not reachable — or not answerable for any reason that is not transient, a
  404 for a commit GitHub never had included — it is judged as an open checkpoint, never as
  already merged. Only a transient fault (`MergePrecondition.transient?/1`) is an error.

  ## A checkpoint the base already contains

  A checkpoint whose merge base with the base branch IS the checkpoint is one the base already
  CONTAINS. It is answered as merged with `on_base?: true` and the checkpoint's own sha as
  `merge_sha` (the commit the base is known to contain), whether or not a `merge_commit_sha`
  was recorded, and `MergePrecondition` decides what that means: `already_merged` only when a
  recorded allow names the checkpoint, and otherwise `checkpoint_on_base_without_allow` — the
  commit the branch was cut from with no work on it, or a fast-forward nobody gated.

  The check runs on a MISSING branch too, before it is answered `:missing`: a branch deleted
  after its checkpoint was fast-forwarded onto the base is contained, not missing. The
  comparison there is best-effort — only a transient fault is an error; any other answer
  (a checkpoint GitHub never had, say) leaves the branch `:missing`.
  """

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Threads.Checkpoint

  @doc """
  The facts of `checkpoint`, in `PullRequestSource.pull_request/0`'s shape plus the thread
  facts listed in the moduledoc. `base_branch` is the one the claim was PLACED on, pinned on
  its implement ledger row (the source's current one only for a row that pinned none);
  `branch` is the one the current claim's dispatch named.
  """
  @spec pull_request(String.t(), String.t(), String.t(), Checkpoint.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def pull_request(repo, base_branch, branch, checkpoint, allowed_sha \\ nil)

  def pull_request(repo, base_branch, branch, %Checkpoint{merge_commit_sha: merged} = cp, allowed)
      when is_binary(merged) do
    case source().contains?(repo, merged, base_branch) do
      {:ok, true} -> {:ok, merged_facts(cp, merged)}
      {:ok, false} -> open_facts(repo, base_branch, branch, cp, allowed)
      {:error, reason} -> uncontained(reason, {repo, base_branch, branch, cp, allowed})
    end
  end

  def pull_request(repo, base_branch, branch, %Checkpoint{} = checkpoint, allowed),
    do: open_facts(repo, base_branch, branch, checkpoint, allowed)

  # The containment question could not be answered. Only a TRANSIENT fault is an error — it is
  # retried. Anything else, a 404 for a merge commit GitHub never had included, falls through
  # to judging the checkpoint as open, as the moduledoc promises: an unconfirmed merge is
  # never read as merged.
  defp uncontained(reason, {repo, base_branch, branch, checkpoint, allowed}) do
    if MergePrecondition.transient?(reason),
      do: {:error, reason},
      else: open_facts(repo, base_branch, branch, checkpoint, allowed)
  end

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

  defp open_facts(repo, base_branch, branch, %Checkpoint{commit_sha: sha} = checkpoint, allowed) do
    case branch_head(repo, branch) do
      {:ok, ^sha} -> checkpoint_facts(repo, base_branch, checkpoint)
      {:ok, :missing} -> missing_facts(repo, base_branch, checkpoint)
      {:ok, other} -> moved_facts({repo, base_branch}, sha, other, allowed)
      {:error, _reason} = error -> error
    end
  end

  # A branch head nobody recorded is a moved head — UNLESS the checkpoint is the one the gate
  # ALLOWED and that head has the SHAPE of the merge executor's base update
  # (`base_update_of/3`): between moving the thread branch and recording it (US-45.5).
  # Answered as a transient fault, `{:base_update_in_flight, head}`, so the gate retries
  # rather than sending the story back. A claimant's commit on top of the checkpoint has one
  # parent and is a moved head, as before.
  defp moved_facts({repo, base_branch}, sha, other, sha) do
    on_base? = &source().contains?(repo, &1, base_branch)

    with {:ok, commit} <- source().commit(repo, other),
         {:ok, _second} <- base_update_of(commit, sha, on_base?) do
      {:error, {:base_update_in_flight, other}}
    else
      # Only a TRANSIENT failure of these extra reads is worth a retry. Anything else means the
      # head could not be shown to be a base update, and it is judged as the moved head it was
      # before the question was asked.
      {:error, reason} = error ->
        if MergePrecondition.transient?(reason), do: error, else: moved(sha, other)

      :no ->
        moved(sha, other)
    end
  end

  defp moved_facts(_where, sha, other, _allowed), do: moved(sha, other)

  defp moved(sha, other), do: {:ok, Map.merge(open(sha), %{branch_head_sha: other})}

  @doc """
  Whether `commit` has the shape of the merge executor's base update of `checkpoint_sha`
  (US-45.5): EXACTLY two parents, the first the checkpoint and the second a commit on the
  base branch, which `on_base?` answers (`{:ok, boolean}` or an error). `{:ok, second}`, `:no`,
  or the error. The one predicate for the gate's in-flight answer and the executor's
  recovery of its own base update — anything else, a claimant's single-parent commit on the
  checkpoint included, is a moved head.
  """
  @spec base_update_of(map(), String.t(), (String.t() -> {:ok, boolean()} | {:error, term()})) ::
          {:ok, String.t()} | :no | {:error, term()}
  def base_update_of(%{parents: [checkpoint_sha, second]}, checkpoint_sha, on_base?) do
    case on_base?.(second) do
      {:ok, true} -> {:ok, second}
      {:ok, false} -> :no
      {:error, _reason} = error -> error
    end
  end

  def base_update_of(_commit, _checkpoint_sha, _on_base?), do: :no

  defp checkpoint_facts(repo, base_branch, %Checkpoint{commit_sha: sha} = checkpoint) do
    with {:ok, commit} <- source().commit(repo, sha),
         {:ok, comparison} <- source().compare(repo, base_branch, sha) do
      compared_facts(checkpoint, commit, comparison)
    end
  end

  # The base already contains the checkpoint (see the moduledoc).
  defp compared_facts(%Checkpoint{commit_sha: sha} = checkpoint, _commit, %{merge_base_sha: sha}),
    do: {:ok, on_base_facts(checkpoint)}

  defp compared_facts(%Checkpoint{commit_sha: sha}, commit, comparison) do
    {:ok,
     Map.merge(open(sha), %{
       branch_head_sha: sha,
       merge_base_sha: comparison.merge_base_sha,
       diffstat: comparison.diffstat,
       diff: comparison.diff,
       head_tree_sha: commit.tree_sha,
       base_tree_sha: comparison.base_tree_sha
     })}
  end

  defp open(sha), do: %{state: "open", merged?: false, merge_sha: nil, head_sha: sha}

  # The branch is gone. A checkpoint the base contains was fast-forwarded (or cut from the
  # base) and the branch deleted since, which is not the same fact as "never pushed".
  defp missing_facts(repo, base_branch, %Checkpoint{commit_sha: sha} = checkpoint) do
    case source().compare(repo, base_branch, sha) do
      {:ok, %{merge_base_sha: ^sha}} ->
        {:ok, on_base_facts(checkpoint)}

      {:error, reason} = error ->
        if MergePrecondition.transient?(reason), do: error, else: missing(sha)

      {:ok, _not_contained} ->
        missing(sha)
    end
  end

  defp missing(sha), do: {:ok, Map.merge(open(sha), %{branch_head_sha: :missing})}

  defp on_base_facts(%Checkpoint{commit_sha: sha} = checkpoint),
    do: checkpoint |> merged_facts(sha) |> Map.put(:on_base?, true)

  # A branch the forge does not have is a FACT about the thread — nothing was pushed, or it
  # was deleted — not a forge failure, so it is `:missing` rather than an error that would
  # escalate. But GitHub answers the same 404 for a repository the token cannot see, so the
  # 404 means `:missing` only once the repository itself reads; otherwise the repository's
  # own failure is the answer. Every other failure keeps its classification.
  defp branch_head(repo, branch) do
    case source().branch_head(repo, branch) do
      {:error, {:github_api_error, 404}} ->
        case source().repository_readable(repo) do
          :ok -> {:ok, :missing}
          {:error, _reason} = unreadable -> unreadable
        end

      other ->
        other
    end
  end

  defp source, do: PullRequestSource.impl()
end
