defmodule LoopctlRunner.MergeRun do
  @moduledoc """
  The runner's half of a pull-request-route merge (US-48.17): loopctl's merge gate ALLOWED a head,
  and its `merge` instruction (contract 1.29.0, `RunnerMergeInstruction`) tells the runner holding
  the claim to merge exactly that head. The session never merges (its prompt says so,
  `LoopctlRunner.DispatchPrompt`); this module does, and only on an instruction.

  `execute/4` reads the pull request, decides, merges, and reads it again. It returns what the
  runner reports, and nothing here sends anything:

    * `{:merged, merge_sha}` — report `ci -> merged` with `effects.merge_sha`. Also the answer when
      the pull request is ALREADY merged at the allowed head (a duplicate instruction, or a merge
      whose report was lost), which loopctl answers idempotently;
    * `{:head_moved, head}` — the pull request's head is no longer the allowed one, before the merge
      or because `--match-head-commit` refused it: report `ci -> implementing` over `base_moved`;
    * `{:escalate, reason}` — GitHub said no for another reason, the pull request was closed
      unmerged, or it was merged at a head the gate never allowed: report `ci -> escalated` over
      `session_escalated` with `reason`;
    * `{:not_ours, reason}` — the pull request is not this dispatch's (another head branch or base,
      or a fork's): nothing is merged and nothing reported, since the instruction does not
      describe work this runner holds;
    * `{:unreachable, reason}` — the forge could not be read, or does not yet show an outcome:
      nothing is reported. loopctl resends an instruction that drew no merge report, and its gate
      records a merge it finds already made, so silence is safe where a guess is not.

  A refusal is judged by READING THE PULL REQUEST AGAIN, never by parsing gh's error text: a head
  that moved shows as a different `headRefOid`, a merge that landed despite a lost answer shows as
  `MERGED`, and only a pull request still open at the allowed head after a refused merge is a
  refusal worth a human. A merge whose second read fails is `unreachable`, because it may well
  have happened.

  ## One retry, in-process, before a refusal escalates

  Many refusals are a race, not a decision: GitHub answers "Base branch was modified. Review and
  try the merge again" while a sibling merge lands, and "not mergeable" while it recomputes. So a
  refusal with the pull request still open at the allowed head waits `:retry_after_ms` (default
  5000 ms), READS THE PULL REQUEST AGAIN and judges that read as the first one is judged, and
  merges once more only when it is still open at the allowed head. `--match-head-commit` keeps the
  second merge exactly as safe as the first: it can merge only that head. A second refusal is
  `{:escalate, reason}` with GitHub's own text, as the contract says. The retry is bounded at one,
  so a refusal that never clears (required reviews, strict protection) costs one wait, not a
  loop.

  `forge` is `%{view: (repo, number, timeout_ms -> {:ok, map} | {:error, reason}), merge: (repo,
  number, head_sha, timeout_ms -> :ok | {:refused, out} | {:error, reason})}`,
  `LoopctlRunner.Forge.pull_request/4` and `merge/5` in production. Every value reported — the
  merge sha, the moved head — is GitHub's.
  """

  alias LoopctlRunner.DispatchRun

  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  # A merge waits for GitHub to write the merge commit; a read is a read.
  @view_timeout_ms 30_000
  @merge_timeout_ms 120_000
  # How long a refused merge waits before its one retry: long enough for a sibling merge's base
  # move or GitHub's mergeability recompute to settle, short against loopctl's answer window.
  @retry_after_ms 5_000

  @type outcome ::
          {:merged, String.t()}
          | {:head_moved, String.t()}
          | {:escalate, String.t()}
          | {:not_ours, String.t()}
          | {:unreachable, String.t()}

  @typedoc "The dispatch's own branch and base, which its pull request must be from and into."
  @type where :: %{required(:branch) => String.t(), required(:base) => String.t()}

  @doc """
  Merges the pull request `instruction` names (a validated `RunnerMergeInstruction`) if it is
  `where`'s and open at the allowed head, and says what to report. `opts` may carry
  `:view_timeout_ms`, `:merge_timeout_ms` and `:retry_after_ms`.
  """
  @spec execute(map(), where(), map(), keyword()) :: outcome()
  def execute(instruction, where, forge, opts \\ []) do
    ctx = %{
      instruction: instruction,
      where: where,
      forge: forge,
      view_ms: Keyword.get(opts, :view_timeout_ms, @view_timeout_ms),
      merge_ms: Keyword.get(opts, :merge_timeout_ms, @merge_timeout_ms),
      retry_after_ms: Keyword.get(opts, :retry_after_ms, @retry_after_ms)
    }

    attempt(ctx, 1)
  end

  # `retries` is how many more merges a refusal may draw: one, then the refusal escalates.
  defp attempt(ctx, retries) do
    %{"repo" => repo, "pr_number" => number, "head_sha" => head} = ctx.instruction
    %{view: view, merge: merge} = ctx.forge

    with {:ok, pr} <- read(view, repo, number, ctx.view_ms),
         :merge <- judge(pr, number, head, ctx.where) do
      merged = merge.(repo, number, head, ctx.merge_ms)

      read(view, repo, number, ctx.view_ms)
      |> after_merge(merged, number, head, ctx.where)
      |> retried(ctx, retries)
    end
  end

  defp retried({:refused, _reason}, ctx, retries) when retries > 0 do
    Process.sleep(ctx.retry_after_ms)
    attempt(ctx, retries - 1)
  end

  defp retried({:refused, reason}, _ctx, _retries), do: {:escalate, reason}
  defp retried(outcome, _ctx, _retries), do: outcome

  defp read(view, repo, number, timeout_ms) do
    case view.(repo, number, timeout_ms) do
      {:ok, pr} when is_map(pr) ->
        {:ok, pr}

      {:error, reason} when is_binary(reason) ->
        {:unreachable, "could not read ##{number}: #{reason}"}

      other ->
        {:unreachable, "could not read ##{number}: #{inspect(other, limit: 5)}"}
    end
  end

  # What the second read shows. A pull request still open at the allowed head is the one case the
  # merge's own answer decides.
  defp after_merge({:ok, pr}, merged, number, head, where) do
    case {judge(pr, number, head, where), merged} do
      # Internal, never returned: `attempt/2` retries it once, then escalates it.
      {:merge, {:refused, out}} ->
        {:refused,
         DispatchRun.cap_reason(
           "GitHub refused to merge pull request ##{number} at #{head}: #{out}"
         )}

      {:merge, :ok} ->
        {:unreachable,
         "gh merged ##{number} without error, but GitHub still shows it open at #{head}"}

      {:merge, {:error, reason}} ->
        {:unreachable, "the merge of ##{number} did not complete: #{reason}"}

      {outcome, _merged} ->
        outcome
    end
  end

  defp after_merge({:unreachable, reason}, merged, number, _head, _where),
    do:
      {:unreachable,
       "the merge of ##{number} answered #{inspect(merged, limit: 5)}, and then #{reason}"}

  # What the pull request, as GitHub holds it, says to do.
  defp judge(pr, number, head, where) do
    cond do
      not ours?(pr, number, where) ->
        {:not_ours,
         "pull request ##{number} is not #{where.branch} into #{where.base} in this repository " <>
           "(head #{inspect(pr["headRefName"])}, base #{inspect(pr["baseRefName"])}, " <>
           "cross-repository #{inspect(pr["isCrossRepository"])})"}

      not sha?(pr["headRefOid"]) ->
        {:unreachable, "GitHub names no head commit for ##{number}"}

      true ->
        by_state(pr["state"], pr["headRefOid"], merge_sha(pr), number, head)
    end
  end

  defp by_state("OPEN", head, _merge_sha, _number, head), do: :merge
  defp by_state("OPEN", moved, _merge_sha, _number, _head), do: {:head_moved, moved}

  defp by_state("MERGED", head, merge_sha, _number, head) when is_binary(merge_sha),
    do: {:merged, merge_sha}

  defp by_state("MERGED", head, nil, number, head),
    do: {:unreachable, "##{number} is merged, but GitHub names no merge commit yet"}

  defp by_state("MERGED", other, _merge_sha, number, head),
    do:
      {:escalate,
       "pull request ##{number} was merged at #{other}, not at #{head}, the head the merge gate " <>
         "allowed"}

  defp by_state("CLOSED", _actual, _merge_sha, number, _head),
    do: {:escalate, "pull request ##{number} was closed without being merged"}

  defp by_state(state, _actual, _merge_sha, number, _head),
    do: {:unreachable, "##{number} is in a state this runner does not know: #{inspect(state)}"}

  defp ours?(pr, number, %{branch: branch, base: base}) do
    pr["number"] == number and pr["headRefName"] == branch and pr["baseRefName"] == base and
      pr["isCrossRepository"] == false
  end

  defp merge_sha(%{"mergeCommit" => %{"oid" => oid}}), do: if(sha?(oid), do: oid)
  defp merge_sha(_pr), do: nil

  defp sha?(value) when is_binary(value), do: Regex.match?(@sha, value)
  defp sha?(_value), do: false
end
