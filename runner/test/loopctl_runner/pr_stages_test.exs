defmodule LoopctlRunner.PrStagesTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Contract, DispatchRun, PrStages}

  @head "loop/story-900.216-ddb4fcc1"
  @base "master"
  @head_sha "2fd0c5233b323ca4dc6e4d793536e884c902d8bd"
  @merge_sha "a1076b601b1651bc411b0822e1d89cc5550a03b4"

  # The shape `gh pr list --json` answers with, as read off mkreyman/home_care_billing#3938.
  defp pr(overrides) do
    Map.merge(
      %{
        "number" => 3938,
        "state" => "OPEN",
        "headRefName" => @head,
        "headRefOid" => @head_sha,
        "baseRefName" => @base,
        "isCrossRepository" => false,
        "mergeCommit" => nil,
        "mergedAt" => nil,
        "statusCheckRollup" => []
      },
      overrides
    )
  end

  defp check(status, conclusion),
    do: %{"__typename" => "CheckRun", "status" => status, "conclusion" => conclusion}

  defp green, do: [check("COMPLETED", "SUCCESS"), check("COMPLETED", "SKIPPED")]

  defp merged,
    do:
      pr(%{
        "state" => "MERGED",
        "mergeCommit" => %{"oid" => @merge_sha},
        "mergedAt" => "2026-11-07T11:22:05Z",
        "statusCheckRollup" => green()
      })

  defp tos(observed), do: Enum.map(observed, & &1["to"])

  test "a merged pull request is observed through merged, with the forge's identities" do
    assert PrStages.observed([merged()], @head, @base) == [
             %{"to" => "reviewing", "effects" => %{}},
             %{"to" => "pr_open", "effects" => %{"pr_number" => 3938, "head_sha" => @head_sha}},
             %{"to" => "ci", "effects" => %{"head_sha" => @head_sha}},
             %{"to" => "merged", "effects" => %{"merge_sha" => @merge_sha}}
           ]
  end

  test "every observed stage builds a stage report the vendored contract accepts" do
    dispatch = %{"dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f", "claim_epoch" => 3}

    [%{"effects" => %{}} | _] = observed = PrStages.observed([merged()], @head, @base)

    Enum.reduce(observed, "implementing", fn %{"to" => to, "effects" => effects}, from ->
      effects = if effects == %{}, do: nil, else: effects

      assert {:ok, payload} =
               DispatchRun.stage_report(dispatch, from, to, edge: "forward", effects: effects)

      assert Contract.validate("RunnerStageReport", payload) == :ok
      to
    end)
  end

  test "a merged pull request is past CI whatever its rollup says" do
    assert tos(PrStages.observed([%{merged() | "statusCheckRollup" => []}], @head, @base)) ==
             ~w(reviewing pr_open ci merged)
  end

  test "merged without a merge commit oid is never reported merged" do
    for commit <- [nil, %{}, %{"oid" => "not-a-sha"}] do
      observed = PrStages.observed([%{merged() | "mergeCommit" => commit}], @head, @base)
      assert tos(observed) == ~w(reviewing pr_open ci)
    end
  end

  test "an open pull request with every check completed green stops at ci" do
    statuses = [%{"__typename" => "StatusContext", "state" => "SUCCESS"}]

    for rollup <- [green(), statuses, [check("COMPLETED", "NEUTRAL")]] do
      observed = PrStages.observed([pr(%{"statusCheckRollup" => rollup})], @head, @base)
      assert tos(observed) == ~w(reviewing pr_open ci)
      assert List.last(observed)["effects"] == %{"head_sha" => @head_sha}
    end
  end

  test "an open pull request whose checks are not all green, or absent, stops at pr_open" do
    for rollup <- [
          [],
          nil,
          [check("IN_PROGRESS", nil)],
          [check("COMPLETED", "SUCCESS"), check("COMPLETED", "FAILURE")],
          [check("COMPLETED", "CANCELLED")],
          [%{"__typename" => "StatusContext", "state" => "PENDING"}],
          [%{"__typename" => "Something", "state" => "SUCCESS"}]
        ] do
      observed = PrStages.observed([pr(%{"statusCheckRollup" => rollup})], @head, @base)
      assert tos(observed) == ~w(reviewing pr_open), "rollup #{inspect(rollup)}"
    end
  end

  test "no pull request is nothing" do
    assert PrStages.observed([], @head, @base) == []
  end

  test "a closed, unmerged pull request is nothing" do
    assert PrStages.observed([pr(%{"state" => "CLOSED"})], @head, @base) == []
  end

  test "only a pull request of THIS branch into THIS base, from this repository, counts" do
    for other <- [
          pr(%{"headRefName" => "loop/other"}),
          pr(%{"baseRefName" => "release"}),
          # A fork's branch of the same name is somebody else's pull request.
          pr(%{"isCrossRepository" => true}),
          pr(%{"isCrossRepository" => nil})
        ] do
      assert PrStages.observed([other], @head, @base) == []
    end
  end

  test "the newest pull request of the branch decides" do
    older = %{merged() | "number" => 10}
    newer = pr(%{"number" => 11, "state" => "CLOSED"})
    assert PrStages.observed([older, newer], @head, @base) == []

    assert tos(PrStages.observed([newer, %{older | "number" => 12}], @head, @base)) ==
             ~w(reviewing pr_open ci merged)
  end

  test "a malformed identity reports nothing rather than a stage without it" do
    for bad <- [
          pr(%{"number" => 0}),
          pr(%{"number" => "3938"}),
          pr(%{"headRefOid" => "ABC"}),
          pr(%{"headRefOid" => nil})
        ] do
      assert PrStages.observed([bad], @head, @base) == []
    end
  end

  test "anything that is not a list of pull request objects is nothing" do
    for answer <- [nil, %{}, "[]", [nil], ["x"]] do
      assert PrStages.observed(answer, @head, @base) == []
    end
  end
end
