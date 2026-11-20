defmodule LoopctlRunner.PrStages do
  @moduledoc """
  What the forge says about a `pr`-mode session's own pull request, as the forward stages the
  runner reports for it (US-48.16): pure, so the mapping is tested without a forge.

  The input is the forge's answer about the dispatch's branch and base (`LoopctlRunner.Forge`),
  and it is the ONLY input: nothing here reads session text or a file the session wrote, so every
  value reported — the pull request number, its head sha and its merge commit — is one GitHub
  holds about this branch.

  The pull request is the NEWEST (highest number) whose head is the dispatch's branch, whose base
  is the dispatch's base, and which is not a fork's: a fork's branch of the same name is somebody
  else's pull request. The newest decides even when an older one merged, because the newest is
  the one the session's last delivery attempt is about.

  The mapping, reported in this order and only as far as observed, each over `forward`:

    * no such pull request, or a CLOSED one that never merged — nothing;
    * an OPEN or MERGED one — `reviewing`, then `pr_open` with `pr_number` and `head_sha`;
    * `ci` with `head_sha` — when the pull request MERGED (a merge is past CI on the ladder), or
      when it is open and its head's check rollup is non-empty and every check COMPLETED green
      (`SUCCESS`, `NEUTRAL` or `SKIPPED` for a check run, `SUCCESS` for a commit status). Checks
      still running, any failure, or no checks at all stop it at `pr_open`: the runner reports
      what it saw, and CI it did not see pass is not CI it saw;
    * `merged` with `merge_sha` — only when the forge says MERGED and names the merge commit oid.

  A malformed identity (a number that is not a positive integer, a sha that is not lowercase hex)
  reports nothing at all rather than a stage missing the effect loopctl records for it. The
  effects are the ones loopctl's stage machine writes at each stage (`@effect_stages`: `head_sha`
  at `pr_open` and `ci`, `pr_number` at `pr_open`, `merge_sha` only on the transition into
  `merged`, where it is required).
  """

  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @green_conclusions ~w(SUCCESS NEUTRAL SKIPPED)

  @typedoc "One observed stage: where the story moves to, and the identities that move records."
  @type observed :: %{required(String.t()) => String.t() | map()}

  @doc """
  The forward stages `prs` (the forge's answer) shows for `head` into `base`, in order, each
  `%{"to" => stage, "effects" => map}`; `[]` when it shows none.
  """
  @spec observed(term(), String.t(), String.t()) :: [observed()]
  def observed(prs, head, base) when is_list(prs) do
    prs
    |> Enum.filter(&own?(&1, head, base))
    |> Enum.max_by(& &1["number"], fn -> nil end)
    |> stages()
  end

  def observed(_answer, _head, _base), do: []

  defp own?(
         %{"headRefName" => head, "baseRefName" => base, "isCrossRepository" => false} = pr,
         head,
         base
       ),
       do: is_integer(pr["number"])

  defp own?(_pr, _head, _base), do: false

  defp stages(nil), do: []

  defp stages(%{"number" => number, "headRefOid" => head_sha, "state" => state} = pr)
       when number > 0 and is_binary(head_sha) and state in ["OPEN", "MERGED"] do
    merge_sha = merge_sha(pr)
    past_ci? = state == "MERGED" or green?(pr["statusCheckRollup"])

    cond do
      not sha?(head_sha) ->
        []

      # `merged` only ever follows `ci`, and a merge is past CI, so a MERGED one with its merge
      # commit named is the whole ladder.
      state == "MERGED" and merge_sha != nil ->
        opened(number, head_sha) ++ [ci(head_sha), merged(merge_sha)]

      past_ci? ->
        opened(number, head_sha) ++ [ci(head_sha)]

      true ->
        opened(number, head_sha)
    end
  end

  defp stages(_pr), do: []

  defp opened(number, head_sha),
    do: [
      %{"to" => "reviewing", "effects" => %{}},
      %{"to" => "pr_open", "effects" => %{"pr_number" => number, "head_sha" => head_sha}}
    ]

  defp ci(head_sha), do: %{"to" => "ci", "effects" => %{"head_sha" => head_sha}}
  defp merged(merge_sha), do: %{"to" => "merged", "effects" => %{"merge_sha" => merge_sha}}

  defp merge_sha(%{"mergeCommit" => %{"oid" => oid}}) when is_binary(oid),
    do: if(sha?(oid), do: oid)

  defp merge_sha(_pr), do: nil

  defp sha?(value), do: Regex.match?(@sha, value)

  # Every check of the head completed green, and there was at least one to see.
  defp green?([_ | _] = rollup), do: Enum.all?(rollup, &green_check?/1)
  defp green?(_rollup), do: false

  defp green_check?(%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => c}),
    do: c in @green_conclusions

  defp green_check?(%{"__typename" => "StatusContext", "state" => "SUCCESS"}), do: true
  defp green_check?(_check), do: false
end
