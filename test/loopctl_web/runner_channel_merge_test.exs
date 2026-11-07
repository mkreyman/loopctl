defmodule LoopctlWeb.RunnerChannelMergeTest do
  @moduledoc """
  US-48.17 over a real runner socket: `Loopctl.Runners.instruct_merge/3` hands a
  `RunnerMergeInstruction` (contract 1.29.0) to the runner's channel, which pushes `merge`.

  Every refusal before the broadcast — an invalid instruction, a halted tenant, a runner of
  another tenant, no live socket, a runner that joined on a contract older than 1.29.0 — sends
  nothing. The channel reaches the test's sandbox connection through `$callers`, as in
  `LoopctlWeb.RunnerChannelStageTest`.
  """

  use LoopctlWeb.ChannelCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Runners
  alias Loopctl.Tenants.Tenant

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 2})
    %{tenant: tenant, runner: runner, runner_key: raw}
  end

  test "a 1.29.0 runner is pushed exactly the instruction", ctx do
    channel = join_runner(ctx)
    instruction = instruction()

    assert :ok = Runners.instruct_merge(ctx.tenant.id, ctx.runner.id, instruction)
    assert_push "merge", pushed, reply_timeout()

    assert pushed == %{
             dispatch_id: instruction["dispatch_id"],
             claim_epoch: 3,
             story_id: instruction["story_id"],
             repo: "acme/widgets",
             pr_number: 4242,
             head_sha: instruction["head_sha"],
             merge_method: "squash"
           }

    leave_channel(channel)
  end

  test "a runner that joined on 1.28.0 is never sent one", ctx do
    channel = join_runner(ctx, "1.28.0")

    assert {:error, :runner_contract_too_old} =
             Runners.instruct_merge(ctx.tenant.id, ctx.runner.id, instruction())

    refute_push "merge", _
    leave_channel(channel)
  end

  test "no live socket, another tenant's runner, an invalid instruction send nothing", ctx do
    assert {:error, :runner_not_connected} =
             Runners.instruct_merge(ctx.tenant.id, ctx.runner.id, instruction())

    channel = join_runner(ctx)
    other = fixture(:tenant, %{trust_tier: :human_anchored})

    assert {:error, :not_authorized} =
             Runners.instruct_merge(other.id, ctx.runner.id, instruction())

    for bad <- [
          Map.put(instruction(), "merge_method", "merge"),
          Map.delete(instruction(), "head_sha"),
          Map.put(instruction(), "head_sha", "not-a-sha"),
          Map.put(instruction(), "pr_number", 0),
          Map.put(instruction(), "extra", "field")
        ] do
      assert {:error, {:invalid, [_ | _]}} =
               Runners.instruct_merge(ctx.tenant.id, ctx.runner.id, bad)
    end

    refute_push "merge", _
    leave_channel(channel)
  end

  test "a halted tenant is refused before the broadcast, and the channel re-checks", ctx do
    channel = join_runner(ctx)

    Tenant
    |> AdminRepo.get!(ctx.tenant.id)
    |> Ecto.Changeset.change(custody_halted_at: DateTime.utc_now())
    |> AdminRepo.update!()

    assert {:error, :tenant_halted} =
             Runners.instruct_merge(ctx.tenant.id, ctx.runner.id, instruction())

    # A broadcast already in flight when the halt was armed: the channel itself declines.
    {:ok, cast} = RunnerContract.cast_merge_instruction(instruction())
    send(channel.channel_pid, {:runner_merge_instruction, cast})
    _ = :sys.get_state(channel.channel_pid)

    refute_push "merge", _
    leave_channel(channel)
  end

  defp instruction do
    %{
      "dispatch_id" => Ecto.UUID.generate(),
      "claim_epoch" => 3,
      "story_id" => Ecto.UUID.generate(),
      "repo" => "acme/widgets",
      "pr_number" => 4242,
      "head_sha" => String.duplicate("a", 40),
      "merge_method" => "squash"
    }
  end

  defp join_runner(ctx, version \\ RunnerContract.version()) do
    {:ok, socket} = connect_runner_socket(ctx.runner_key)

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> ctx.runner.id,
        build(:runner_join_payload, %{
          "contract_version" => version,
          "machine" => "minis",
          "repos" => [],
          "max_sessions" => 2
        })
      )

    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  defp leave_channel(channel) do
    Process.unlink(channel.channel_pid)
    leave(channel)
  end
end
