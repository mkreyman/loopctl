defmodule LoopctlRunner.ContractTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Contract, Health}

  defp join(overrides \\ %{}) do
    Map.merge(
      %{
        "contract_version" => "1.4.0",
        "machine" => "minis",
        "cores" => 16,
        "memory_mb" => 28_000,
        "repos" => ["mkreyman/home_care_billing"],
        "max_sessions" => 2,
        "in_flight" => 0,
        "draining" => false
      },
      overrides
    )
  end

  test "the vendored contract is v1.4.0 and names the socket and header the client uses" do
    assert Contract.version() == "1.4.0"

    assert %{
             "credential_header" => "x-loopctl-runner-token",
             "socket_path" => "/runner/socket/websocket",
             "topic" => "runner:{runner_id}"
           } = Contract.connection()
  end

  test "uuid and date-time formats are enforced, as loopctl casts them" do
    reply = %{
      "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
      "claim_epoch" => 0,
      "decision" => "refused",
      "reason" => "dispatches_disabled"
    }

    assert Contract.validate("RunnerDispatchReply", reply) == :ok

    assert {:error, [msg]} =
             Contract.validate("RunnerDispatchReply", %{reply | "dispatch_id" => "d-1"})

    assert msg =~ "is not a uuid"

    assert {:error, [msg]} =
             Contract.validate("RunnerTraceCursor", %{"run_id" => "7d0c1f6e-3b1a-4f7e-9c2d"})

    assert msg =~ "is not a uuid"

    assert {:error, [msg]} =
             Contract.validate("RunnerStatus", %{
               "in_flight" => 0,
               "draining" => true,
               "sample" => %{
                 "sampled_at" => "yesterday",
                 "loadavg_1m" => 1.0,
                 "free_ram_mb" => 1,
                 "free_disk_mb" => 1,
                 "last_build_at" => nil
               }
             })

    assert msg =~ "is not an RFC 3339 date-time"
  end

  test "a complete join validates" do
    assert Contract.validate("RunnerJoin", join()) == :ok
  end

  test "each constraint the contract declares is enforced" do
    assert {:error, [msg]} = Contract.validate("RunnerJoin", Map.delete(join(), "machine"))
    assert msg =~ "missing machine"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"machine" => "Minis!"}))
    assert msg =~ "does not match"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"max_sessions" => 65}))
    assert msg =~ "above maximum"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"cores" => "16"}))
    assert msg =~ "expected"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"repos" => ["not a repo"]}))
    assert msg =~ "repos[0]"

    assert {:error, [msg]} = Contract.validate("RunnerStatus", %{})
    assert msg =~ "fewer than 1 properties"

    assert {:error, [msg]} =
             Contract.validate("RunnerDispatch", %{
               "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
               "story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
               "kind" => "deploy",
               "repo" => "a/b",
               "base_branch" => "master",
               "branch" => "loop/x",
               "claim_epoch" => 0,
               "wall_clock_seconds" => 60,
               "max_turns" => 5
             })

    assert msg =~ "not in"
  end

  test "a sample from this machine satisfies RunnerSample" do
    sample = Health.sample(System.tmp_dir!(), nil)
    assert is_map(sample)
    assert Contract.validate("RunnerSample", sample) == :ok
    assert {:ok, %{"cores" => cores, "memory_mb" => mb}} = Health.capacity()
    assert cores >= 1 and mb >= 1
  end

  describe "with a PATH that cannot find the tools" do
    setup do
      original = System.get_env("PATH")
      # An empty directory: nothing is found by PATH, so only the fallback can succeed.
      System.put_env("PATH", LoopctlRunner.TestSupport.tmp_dir!("empty-path"))
      on_exit(fn -> System.put_env("PATH", original) end)
    end

    test "each tool the health check runs is still found at its standard location" do
      assert Health.executable("df") in ["/bin/df", "/usr/bin/df"]

      if :os.type() == {:unix, :darwin} do
        assert Health.executable("sysctl") in ["/usr/sbin/sysctl", "/sbin/sysctl"]
        assert Health.executable("vm_stat") == "/usr/bin/vm_stat"
      end

      assert Health.executable("no-such-tool") == nil
    end

    test "capacity and a sample are still readable" do
      assert {:ok, %{"memory_mb" => mb}} = Health.capacity()
      assert mb >= 1
      assert is_map(Health.sample(System.tmp_dir!(), nil))
    end
  end

  test "every keyword the vendored file uses is one the validator implements" do
    # validate/2 reports an unimplemented keyword as a failure; walk every $defs entry
    # with a value that reaches every nested schema, and look for that message.
    schema =
      Path.expand("../../priv/runner_contract/v1.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    for {name, _} <- schema["$defs"] do
      {_, errors} =
        case Contract.validate(name, %{}) do
          :ok -> {:ok, []}
          other -> other
        end

      refute Enum.any?(errors, &(&1 =~ "does not implement")), "#{name}: #{inspect(errors)}"
    end

    nested = %{
      "sample" => %{
        "sampled_at" => "2026-09-13T05:00:00Z",
        "loadavg_1m" => 0,
        "free_ram_mb" => 0,
        "free_disk_mb" => 0
      }
    }

    assert Contract.validate("RunnerStatus", nested) == :ok

    # The trace batch nests its event schema under items; one event reaches it.
    run_id = "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f"

    batch = %{
      "run_id" => run_id,
      "dispatch_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
      "claim_epoch" => 0,
      "events" => [
        %{
          "run_id" => run_id,
          "seq" => 0,
          "event_id" => "0",
          "parent" => nil,
          "ts" => "2026-09-13T05:00:00Z",
          "type" => "run.started",
          "data" => %{}
        }
      ]
    }

    assert Contract.validate("RunnerTraceBatch", batch) == :ok
  end
end
