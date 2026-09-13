defmodule LoopctlRunner.ContractTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Contract, Health}

  defp join(overrides \\ %{}) do
    Map.merge(
      %{
        "contract_version" => "1.0.0",
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

  test "the vendored contract is v1.0.0 and names the socket and header the client uses" do
    assert Contract.version() == "1.0.0"

    assert %{
             "credential_header" => "x-loopctl-runner-token",
             "socket_path" => "/runner/socket/websocket",
             "topic" => "runner:{runner_id}"
           } = Contract.connection()
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
               "dispatch_id" => "d",
               "story_id" => "s",
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
        "sampled_at" => "x",
        "loadavg_1m" => 0,
        "free_ram_mb" => 0,
        "free_disk_mb" => 0
      }
    }

    assert Contract.validate("RunnerStatus", nested) == :ok
  end
end
