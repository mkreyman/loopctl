defmodule LoopctlRunner.ForgeTest do
  # Each test writes its own fake `gh` and passes its path in: nothing global is touched, and no
  # test ever reaches GitHub.
  use ExUnit.Case, async: true

  alias LoopctlRunner.Forge
  import LoopctlRunner.TestSupport

  # A fake `gh` that records its argv (one per line) and whether the prompt guard reached it, then
  # behaves as `body` says.
  defp fake_gh!(body) do
    dir = tmp_dir!("forge")
    record = Path.join(dir, "argv")
    gh = Path.join(dir, "gh")

    File.write!(gh, """
    #!/bin/sh
    printf '%s\\n' "$@" > #{record}
    printf 'GH_PROMPT_DISABLED=%s\\n' "$GH_PROMPT_DISABLED" >> #{record}
    #{body}
    """)

    File.chmod!(gh, 0o755)
    {gh, record}
  end

  test "asks for the branch's pull requests into the base, every state, the fields the mapping reads" do
    {gh, record} = fake_gh!("echo '[]'")

    assert Forge.pull_requests("mkreyman/home_care_billing", "loop/story-1", "master", 5_000, gh) ==
             {:ok, []}

    assert File.read!(record) |> String.split("\n", trim: true) == [
             "pr",
             "list",
             "--repo",
             "mkreyman/home_care_billing",
             "--head",
             "loop/story-1",
             "--base",
             "master",
             "--state",
             "all",
             "--limit",
             "5",
             "--json",
             "number,state,headRefName,headRefOid,baseRefName,isCrossRepository,mergeCommit," <>
               "mergedAt,statusCheckRollup",
             # Nothing it runs can stop to ask: there is nobody to answer.
             "GH_PROMPT_DISABLED=1"
           ]
  end

  test "the decoded answer is returned as the forge gave it" do
    {gh, _record} = fake_gh!(~S(echo '[{"number":7,"state":"OPEN"}]'))

    assert Forge.pull_requests("o/r", "loop/x", "master", 5_000, gh) ==
             {:ok, [%{"number" => 7, "state" => "OPEN"}]}
  end

  test "a failing gh is an error naming its exit status, never an empty answer" do
    {gh, _record} = fake_gh!("echo 'HTTP 404: Not Found' >&2; exit 1")

    assert {:error, "gh exited 1: HTTP 404: Not Found" <> _} =
             Forge.pull_requests("o/r", "loop/x", "master", 5_000, gh)
  end

  test "an answer that is not a JSON list is an error" do
    for out <- ["not json", ~S({"number":1})] do
      {gh, _record} = fake_gh!("echo '#{out}'")

      assert {:error, "gh answered something that is not a JSON list" <> _} =
               Forge.pull_requests("o/r", "loop/x", "master", 5_000, gh)
    end
  end

  test "a gh that does not answer in time is killed and is an error" do
    {gh, _record} = fake_gh!("sleep 30")
    started = System.monotonic_time(:millisecond)

    assert Forge.pull_requests("o/r", "loop/x", "master", 300, gh) ==
             {:error, "gh did not answer within 300 ms"}

    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  test "no gh to run is an error, not a crash" do
    missing = Path.join(tmp_dir!("forge-missing"), "gh")

    assert {:error, "gh is not installed" <> _} =
             Forge.pull_requests("o/r", "loop/x", "master", 5_000, missing)

    assert {:error, "gh is not installed" <> _} = Forge.pull_request("o/r", 7, 5_000, missing)

    assert {:error, "gh is not installed" <> _} =
             Forge.merge("o/r", 7, String.duplicate("a", 40), 5_000, missing)
  end

  describe "the merge loopctl instructs (US-48.17)" do
    @head String.duplicate("ab", 20)

    defp argv(record),
      do: record |> File.read!() |> String.split("\n", trim: true) |> Enum.drop(-1)

    test "a pull request is read by number, with the fields the merge decides on" do
      {gh, record} = fake_gh!(~S(echo '{"number":7,"state":"OPEN"}'))

      assert Forge.pull_request("mkreyman/home_care_billing", 7, 5_000, gh) ==
               {:ok, %{"number" => 7, "state" => "OPEN"}}

      assert argv(record) == [
               "pr",
               "view",
               "7",
               "--repo",
               "mkreyman/home_care_billing",
               "--json",
               "number,state,headRefName,headRefOid,baseRefName,isCrossRepository,mergeCommit"
             ]

      assert File.read!(record) =~ "GH_PROMPT_DISABLED=1"
    end

    test "a view that is not a JSON object, or a failing gh, is an error" do
      {gh, _record} = fake_gh!("echo '[]'")

      assert {:error, "gh answered something that is not a JSON object" <> _} =
               Forge.pull_request("o/r", 7, 5_000, gh)

      {gh, _record} = fake_gh!("echo 'HTTP 502' >&2; exit 1")
      assert {:error, "gh exited 1: HTTP 502" <> _} = Forge.pull_request("o/r", 7, 5_000, gh)
    end

    test "the merge is a squash of exactly the allowed head, and nothing that bypasses or defers" do
      {gh, record} = fake_gh!("exit 0")

      assert Forge.merge("mkreyman/home_care_billing", 3938, @head, 5_000, gh) == :ok

      assert argv(record) == [
               "pr",
               "merge",
               "3938",
               "--repo",
               "mkreyman/home_care_billing",
               "--squash",
               "--match-head-commit",
               @head
             ]

      assert argv(record) == Forge.merge_args("mkreyman/home_care_billing", 3938, @head)

      for flag <- ~w(--admin --auto --delete-branch --merge --rebase),
          do: refute(flag in argv(record), flag)
    end

    test "a merge gh refuses is a refusal carrying its output, never :ok" do
      {gh, _record} =
        fake_gh!(
          "echo 'GraphQL: Head branch was modified. Review and try the merge again.' >&2; exit 1"
        )

      assert {:refused, "gh exited 1: GraphQL: Head branch was modified" <> _} =
               Forge.merge("o/r", 7, @head, 5_000, gh)
    end

    test "a merge that does not answer in time is an error, which says nothing about the merge" do
      {gh, _record} = fake_gh!("sleep 30")

      assert Forge.merge("o/r", 7, @head, 300, gh) == {:error, "gh did not answer within 300 ms"}
    end
  end
end
