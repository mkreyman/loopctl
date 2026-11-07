defmodule LoopctlRunner.MergeRunTest do
  # The forge is injected: each test passes the answers it wants, and nothing reaches GitHub.
  use ExUnit.Case, async: true

  alias LoopctlRunner.MergeRun

  @head String.duplicate("ab", 20)
  @moved String.duplicate("cd", 20)
  @merge_sha String.duplicate("ef", 20)
  @where %{branch: "loop/story-1", base: "master"}
  @no_wait [retry_after_ms: 0]

  defp instruction(overrides \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
        "claim_epoch" => 3,
        "story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
        "repo" => "mkreyman/fixture",
        "pr_number" => 3938,
        "head_sha" => @head,
        "merge_method" => "squash"
      },
      overrides
    )
  end

  defp pr(overrides) do
    Map.merge(
      %{
        "number" => 3938,
        "state" => "OPEN",
        "headRefName" => "loop/story-1",
        "headRefOid" => @head,
        "baseRefName" => "master",
        "isCrossRepository" => false,
        "mergeCommit" => nil
      },
      overrides
    )
  end

  # A forge whose reads answer `views` in order (the last repeats) and whose merge answers
  # `merged`, telling the test every call.
  defp forge(views, merged \\ :ok) do
    test = self()
    {:ok, reads} = Agent.start_link(fn -> views end)

    view = fn repo, number, _timeout ->
      send(test, {:view, repo, number})

      Agent.get_and_update(reads, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end

    # `merged` is one answer for every merge, or a list answered in order (the last repeats).
    {:ok, answers} = Agent.start_link(fn -> List.wrap(merged) end)

    merge = fn repo, number, head, _timeout ->
      send(test, {:merge, repo, number, head})

      Agent.get_and_update(answers, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end

    %{view: view, merge: merge}
  end

  test "an open pull request at the allowed head is merged once, and the merge commit reported" do
    forge =
      forge([
        {:ok, pr(%{})},
        {:ok, pr(%{"state" => "MERGED", "mergeCommit" => %{"oid" => @merge_sha}})}
      ])

    assert MergeRun.execute(instruction(), @where, forge) == {:merged, @merge_sha}
    assert_received {:merge, "mkreyman/fixture", 3938, @head}
    refute_received {:merge, _, _, _}
    # Read before and after: the merge sha is GitHub's, never gh's text.
    assert_received {:view, "mkreyman/fixture", 3938}
    assert_received {:view, "mkreyman/fixture", 3938}
  end

  test "a pull request already merged at the allowed head is adopted: no second merge" do
    merged = pr(%{"state" => "MERGED", "mergeCommit" => %{"oid" => @merge_sha}})

    assert MergeRun.execute(instruction(), @where, forge([{:ok, merged}])) ==
             {:merged, @merge_sha}

    refute_received {:merge, _, _, _}
  end

  test "a head that moved before the merge merges nothing and reports the moved head" do
    assert MergeRun.execute(instruction(), @where, forge([{:ok, pr(%{"headRefOid" => @moved})}])) ==
             {:head_moved, @moved}

    refute_received {:merge, _, _, _}
  end

  test "a merge --match-head-commit refused because the head moved is read as the moved head" do
    forge =
      forge(
        [{:ok, pr(%{})}, {:ok, pr(%{"headRefOid" => @moved})}],
        {:refused, "gh exited 1: Head branch was modified"}
      )

    assert MergeRun.execute(instruction(), @where, forge) == {:head_moved, @moved}
  end

  test "any other refusal, with the pull request still open at the head, escalates naming it" do
    forge =
      forge(
        [{:ok, pr(%{})}],
        {:refused, "gh exited 1: Pull request is not mergeable: required reviews"}
      )

    assert {:escalate, reason} = MergeRun.execute(instruction(), @where, forge, @no_wait)
    assert reason =~ "GitHub refused to merge pull request #3938 at #{@head}"
    assert reason =~ "required reviews"
    # Escalated only once its one retry was refused too: two merges, never a third.
    assert_received {:merge, "mkreyman/fixture", 3938, @head}
    assert_received {:merge, "mkreyman/fixture", 3938, @head}
    refute_received {:merge, _, _, _}
  end

  test "a refusal that clears on the one retry, after a wait and a fresh read, is the merge" do
    forge =
      forge(
        [
          {:ok, pr(%{})},
          {:ok, pr(%{})},
          {:ok, pr(%{})},
          {:ok, pr(%{"state" => "MERGED", "mergeCommit" => %{"oid" => @merge_sha}})}
        ],
        [
          {:refused, "gh exited 1: Base branch was modified. Review and try the merge again."},
          :ok
        ]
      )

    {micros, outcome} =
      :timer.tc(fn -> MergeRun.execute(instruction(), @where, forge, retry_after_ms: 50) end)

    assert outcome == {:merged, @merge_sha}
    assert micros >= 50_000
    for _ <- 1..4, do: assert_received({:view, "mkreyman/fixture", 3938})
  end

  test "a retry whose fresh read shows a moved head merges nothing more" do
    forge =
      forge(
        [{:ok, pr(%{})}, {:ok, pr(%{})}, {:ok, pr(%{"headRefOid" => @moved})}],
        {:refused, "gh exited 1: Base branch was modified."}
      )

    assert MergeRun.execute(instruction(), @where, forge, @no_wait) == {:head_moved, @moved}
    assert_received {:merge, _, _, _}
    refute_received {:merge, _, _, _}
  end

  test "a refused merge that landed anyway (a lost answer) is the merge" do
    forge =
      forge(
        [
          {:ok, pr(%{})},
          {:ok, pr(%{"state" => "MERGED", "mergeCommit" => %{"oid" => @merge_sha}})}
        ],
        {:refused, "gh exited 1: already merged"}
      )

    assert MergeRun.execute(instruction(), @where, forge) == {:merged, @merge_sha}
  end

  test "a merge whose outcome cannot be read reports nothing: it may have happened" do
    forge = forge([{:ok, pr(%{})}, {:error, "gh exited 1: HTTP 502"}], {:error, "timeout"})

    assert {:unreachable, reason} = MergeRun.execute(instruction(), @where, forge)
    assert reason =~ "HTTP 502"
  end

  test "gh merged without error but the pull request still reads open: nothing reported" do
    assert {:unreachable, reason} =
             MergeRun.execute(instruction(), @where, forge([{:ok, pr(%{})}], :ok))

    assert reason =~ "still shows it open"
  end

  test "a merge that timed out with the pull request still open reports nothing" do
    assert {:unreachable, _} =
             MergeRun.execute(instruction(), @where, forge([{:ok, pr(%{})}], {:error, "timeout"}))
  end

  test "a forge that cannot be read merges nothing and reports nothing" do
    assert {:unreachable, reason} =
             MergeRun.execute(instruction(), @where, forge([{:error, "gh is not installed"}]))

    assert reason =~ "gh is not installed"
    refute_received {:merge, _, _, _}

    assert {:unreachable, _} = MergeRun.execute(instruction(), @where, forge([:nonsense]))
  end

  test "a pull request that is not this dispatch's branch into its base is not merged" do
    for other <- [
          %{"headRefName" => "loop/someone-else"},
          %{"baseRefName" => "release/2"},
          %{"isCrossRepository" => true},
          %{"number" => 1}
        ] do
      assert {:not_ours, _} =
               MergeRun.execute(instruction(), @where, forge([{:ok, pr(other)}])),
             inspect(other)
    end

    refute_received {:merge, _, _, _}
  end

  test "merged at a head the gate never allowed escalates, never reports that merge as gated" do
    merged =
      pr(%{"state" => "MERGED", "headRefOid" => @moved, "mergeCommit" => %{"oid" => @merge_sha}})

    assert {:escalate, reason} = MergeRun.execute(instruction(), @where, forge([{:ok, merged}]))
    assert reason =~ "merged at #{@moved}, not at #{@head}"
  end

  test "merged with no merge commit named yet reports nothing" do
    merged = pr(%{"state" => "MERGED", "mergeCommit" => nil})
    assert {:unreachable, _} = MergeRun.execute(instruction(), @where, forge([{:ok, merged}]))

    malformed = pr(%{"state" => "MERGED", "mergeCommit" => %{"oid" => "not-a-sha"}})
    assert {:unreachable, _} = MergeRun.execute(instruction(), @where, forge([{:ok, malformed}]))
  end

  test "closed without merging escalates" do
    assert {:escalate, reason} =
             MergeRun.execute(instruction(), @where, forge([{:ok, pr(%{"state" => "CLOSED"})}]))

    assert reason =~ "closed without being merged"
    refute_received {:merge, _, _, _}
  end

  test "a head GitHub does not name, or a state it does not know, reports nothing" do
    assert {:unreachable, _} =
             MergeRun.execute(instruction(), @where, forge([{:ok, pr(%{"headRefOid" => nil})}]))

    assert {:unreachable, _} =
             MergeRun.execute(instruction(), @where, forge([{:ok, pr(%{"state" => "DRAFT"})}]))

    refute_received {:merge, _, _, _}
  end
end
