defmodule LoopctlE2e.RunTest do
  @moduledoc "TC-52.9.4 and TC-52.9.5: the stage machine and the leftover checks, against a stub."
  use ExUnit.Case, async: true

  alias LoopctlE2e.Run
  alias LoopctlE2e.StubClient

  @repo "o/sandbox"
  @story %{"id" => "abcdef12-0000-4000-8000-000000000000", "number" => 7}
  @stage "/api/v1/stories/#{@story["id"]}/stage"
  @sandbox %{repo: @repo, project_id: "p-1", label: "loopctl"}

  defp clock do
    {:ok, pid} = Agent.start_link(fn -> %{now: 0, sleeps: []} end)

    opts = [
      now: fn -> Agent.get(pid, & &1.now) end,
      sleep: fn ms -> Agent.update(pid, &%{&1 | now: &1.now + ms, sleeps: [ms | &1.sleeps]}) end
    ]

    {opts, fn -> pid |> Agent.get(& &1.sleeps) |> Enum.reverse() end}
  end

  defp stage(name), do: {:ok, 200, %{"stage" => %{"stage" => name, "escalation_reason" => nil}}}

  @long_id "20261120010203abcdef"

  defp seed_path(run_id), do: "/repos/#{@repo}/contents/lib/sandbox/runs/r#{run_id}.ex"

  defp happy_script do
    pr = %{"number" => 3, "head" => %{"ref" => "loopctl/story-7-abcdef12", "sha" => "h1"}}

    %{
      {:github, :put, seed_path("r1")} => [{:ok, 201, %{}}],
      {:github, :put, seed_path(@long_id)} => [{:ok, 201, %{}}],
      {:github, :post, "/repos/#{@repo}/issues"} => [{:ok, 201, %{"number" => 5}}],
      {:loopctl, :get, "/api/v1/stories"} => [
        {:ok, 200, %{"data" => []}},
        {:ok, 200, %{"data" => [@story]}}
      ],
      {:loopctl, :get, @stage} => [stage("triaged"), stage("claimed"), stage("done")],
      {:github, :get, "/repos/#{@repo}/pulls"} => [{:ok, 200, [pr]}, {:ok, 200, []}],
      {:github, :get, "/repos/#{@repo}/pulls/3"} => [
        {:ok, 200, Map.put(pr, "state", "open")},
        {:ok, 200, Map.put(pr, "state", "open")},
        {:ok, 200, %{"state" => "closed", "merged" => true, "merge_commit_sha" => "m1"}}
      ],
      {:github, :get, "/repos/#{@repo}/actions/runs"} => [
        {:ok, 200,
         %{
           "workflow_runs" => [
             %{"id" => 1, "workflow_id" => 10, "name" => "CI", "status" => "in_progress"}
           ]
         }},
        {:ok, 200,
         %{
           "workflow_runs" => [
             %{
               "id" => 1,
               "workflow_id" => 10,
               "name" => "CI",
               "status" => "completed",
               "conclusion" => "success"
             }
           ]
         }}
      ],
      {:github, :get, "/repos/#{@repo}/pulls/3/reviews"} => [{:ok, 200, [%{"id" => 1}]}],
      {:github, :get, "/repos/#{@repo}/deployments"} => [{:ok, 200, [%{"id" => 9}]}],
      {:github, :get, "/repos/#{@repo}/deployments/9/statuses"} => [
        {:ok, 200, [%{"state" => "success"}]}
      ],
      {:github, :get, "/repos/#{@repo}/issues/5"} => [
        {:ok, 200, %{"state" => "closed", "labels" => [%{"name" => "loopctl:resolution-fixed"}]}}
      ],
      {:loopctl, :get, "/api/v1/escalations"} => [{:ok, 200, %{"data" => []}}]
    }
  end

  test "a run opens its issue and walks every stage in order to a clean done" do
    client = StubClient.start(happy_script())
    {opts, sleeps} = clock()

    assert {:ok, ctx} = Run.execute(client, @sandbox, @long_id, opts)
    assert ctx.story == @story
    assert ctx.pr == 3
    assert ctx.merge_sha == "m1"

    # The defect is on master before the issue reporting it exists.
    [{{:github, :put, put_path}, seed}, {{:github, :post, _}, issue} | _] =
      StubClient.calls(client)

    assert put_path == seed_path(@long_id)
    source = Base.decode64!(seed.content)
    assert source =~ "defmodule Sandbox.Runs.R#{@long_id} do"
    assert source =~ ~s(def value, do: "unset")
    assert source =~ ~s(Returns this run's id, `\\"#{@long_id}\\"`)

    assert issue.title ==
             "e2e #{@long_id}: Sandbox.Runs.R#{@long_id}.value/0 returns \"unset\" instead of #{@long_id}"

    assert issue.body =~ "lib/sandbox/runs/r#{@long_id}.ex"
    assert issue.labels == ["loopctl"]

    # One wait for the story and one for the checks, each the first poll interval.
    assert sleeps.() == [10_000, 10_000]

    assert {{:loopctl, :get, "/api/v1/stories"},
            [project_id: "p-1", issue_number: 5, repo: @repo]} in StubClient.calls(client)

    # CI is the push runs of the PR's branch at its head, the evidence the merge gate counts.
    assert {{:github, :get, "/repos/#{@repo}/actions/runs"},
            [head_sha: "h1", branch: "loopctl/story-7-abcdef12", event: "push", per_page: 100]} in StubClient.calls(
             client
           )
  end

  test "a stage not reached within its budget fails the run naming it, with backoff to 120 s" do
    script = %{
      happy_script()
      | {:loopctl, :get, @stage} => [stage("triaged"), stage("queued")]
    }

    client = StubClient.start(script)
    {opts, sleeps} = clock()

    assert {:error, failure} = Run.execute(client, @sandbox, "r1", opts)
    assert failure == %{stage: :dispatched, story_id: @story["id"], last_state: "stage queued"}

    waits = sleeps.() |> Enum.drop(1)
    assert Enum.take(waits, 6) == [10_000, 20_000, 40_000, 80_000, 120_000, 120_000]
    assert Enum.sum(waits) == 15 * 60_000
    assert Run.describe(failure) =~ "failed at dispatched (story #{@story["id"]}): stage queued"
  end

  test "the run's 120 minutes cap every stage's own budget" do
    client =
      StubClient.start(%{
        happy_script()
        | {:loopctl, :get, "/api/v1/stories"} => [{:ok, 200, %{"data" => []}}]
      })

    {opts, sleeps} = clock()

    assert {:error, %{stage: :story_created}} =
             Run.execute(client, @sandbox, "r1", Keyword.put(opts, :total_budget_ms, 60_000))

    assert Enum.sum(sleeps.()) == 60_000
  end

  test "an issue that produced more than one story fails at once instead of following one" do
    client =
      StubClient.start(%{
        happy_script()
        | {:loopctl, :get, "/api/v1/stories"} => [
            {:ok, 200, %{"data" => [@story, %{@story | "id" => "another"}]}}
          ]
      })

    {opts, sleeps} = clock()

    assert {:error, %{stage: :story_created, last_state: state}} =
             Run.execute(client, @sandbox, "r1", opts)

    assert state =~ "produced 2 stories"
    assert sleeps.() == []
  end

  test "a story that leaves the main line fails at once, without waiting out the budget" do
    script = %{
      happy_script()
      | {:loopctl, :get, @stage} => [
          {:ok, 200, %{"stage" => %{"stage" => "escalated", "escalation_reason" => "stuck"}}}
        ]
    }

    {opts, sleeps} = clock()

    assert {:error, %{stage: :triaged, last_state: "stage escalated: \"stuck\""}} =
             Run.execute(StubClient.start(script), @sandbox, "r1", opts)

    assert sleeps.() == [10_000]
  end

  test "a sandbox with no project id is refused before any issue is opened" do
    for project_id <- [nil, "", "  ", "PROJECT_ID_UNSET"] do
      client = StubClient.start(happy_script())
      {opts, sleeps} = clock()
      sandbox = %{@sandbox | project_id: project_id}

      assert {:error, failure} = Run.execute(client, sandbox, "r1", opts)
      assert failure.stage == :sandbox
      assert failure.story_id == nil
      assert failure.last_state =~ "LOOPCTL_E2E_PROJECT_ID"
      assert StubClient.calls(client) == [], inspect(project_id)
      assert sleeps.() == []
    end
  end

  test "a seed GitHub refuses fails the run before any issue is opened" do
    client =
      StubClient.start(%{happy_script() | {:github, :put, seed_path("r1")} => [{:ok, 409, %{}}]})

    {opts, _sleeps} = clock()

    assert {:error, %{stage: :seeded, story_id: nil, last_state: state}} =
             Run.execute(client, @sandbox, "r1", opts)

    assert state =~ "409"
    refute Enum.any?(StubClient.calls(client), &match?({{:github, :post, _}, _}, &1))
  end

  test "the seeded module is valid Elixir whose value contradicts its own doc" do
    {path, source} = Run.seed("r1")
    assert path == "lib/sandbox/runs/rr1.ex"
    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert Code.format_string!(source) |> IO.iodata_to_binary() == String.trim_trailing(source)
  end

  test "a transport failure is one failed poll, and the next poll goes on" do
    script = %{
      happy_script()
      | {:loopctl, :get, "/api/v1/stories"} => [
          {:error, "connection refused"},
          {:ok, 200, %{"data" => [@story]}}
        ]
    }

    {opts, _sleeps} = clock()
    assert {:ok, _ctx} = Run.execute(StubClient.start(script), @sandbox, "r1", opts)
  end

  describe "leftovers after done (TC-52.9.5)" do
    test "an open PR, an escalation, an open issue and an unfinished stage are each named" do
      pr = %{"number" => 3, "head" => %{"ref" => "loopctl/story-7-abcdef12"}}

      script = %{
        {:loopctl, :get, @stage} => [stage("merged")],
        {:loopctl, :get, "/api/v1/escalations"} => [
          {:ok, 200, %{"data" => [%{"story_id" => @story["id"]}, %{"story_id" => "other"}]}}
        ],
        {:github, :get, "/repos/#{@repo}/pulls"} => [{:ok, 200, [pr]}],
        {:github, :get, "/repos/#{@repo}/issues/5"} => [{:ok, 200, %{"state" => "open"}}]
      }

      ctx = %{repo: @repo, project_id: "p-1", issue_number: 5, story: @story}

      assert LoopctlE2e.Stages.leftovers(StubClient.start(script), ctx) == [
               "story is at merged, so a dispatch may be in flight",
               "escalation open for the story",
               "PR #3 is still open",
               "issue #5 is open"
             ]
    end

    test "a read that fails is itself a leftover" do
      ctx = %{repo: @repo, project_id: "p-1", issue_number: 5, story: @story}
      left = LoopctlE2e.Stages.leftovers(StubClient.start(%{}), ctx)

      assert length(left) == 4
      assert Enum.all?(left, &(&1 =~ "unread"))
    end
  end

  test "a run id is a timestamp and 6 hex characters, valid inside a module name" do
    id = Run.run_id(~U[2026-11-20 01:02:03Z])

    assert id =~ ~r/\A20261120010203[0-9a-f]{6}\z/
    assert {:ok, _} = Code.string_to_quoted("Sandbox.Runs.R#{id}")
  end
end
