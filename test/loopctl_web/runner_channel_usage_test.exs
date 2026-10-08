defmodule LoopctlWeb.RunnerChannelUsageTest do
  @moduledoc """
  US-44.6, contract 1.17.0: a runner's `status` message carrying `usage`, end to end through the
  channel — cast, stored on the `runners` row, and kept OUT of the Presence meta.

  The socket authenticates the runner through `Loopctl.AdminRepo`, while
  `Loopctl.Runners.Usage` writes the row through the RLS `Loopctl.Repo`. In test both run on the
  test's one sandbox connection (`Loopctl.AdminRepo.Route`), and the channel process reaches it
  through `$callers`, so the runner is sandboxed and the channel's write is visible here.

  Status messages are rate-limited to one per second per socket, so every test pushes at most
  one; a second runner is joined where a test needs two machines (story technical notes).
  """

  use LoopctlWeb.ChannelCase, async: true

  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Usage

  setup :verify_on_exit!

  @eight_days 8 * 24 * 60 * 60

  setup do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
    %{tenant: tenant, runner: runner, channel: join_as(runner, raw, "minis")}
  end

  describe "status with usage" do
    test "a malformed usage object is refused invalid_payload and writes nothing (TC-44.6.1)",
         ctx do
      ref = push(ctx.channel, "status", %{"usage" => %{"exhausted" => "yes"}})
      assert_reply ref, :error, %{reason: "invalid_payload"}, reply_timeout()

      assert row(ctx.runner).usage_exhausted_until == nil
    end

    test "a far reset is stored clamped to eight days, with the account (TC-44.6.2)", ctx do
      far = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second) |> DateTime.to_iso8601()

      ref =
        push(ctx.channel, "status", %{
          "in_flight" => 1,
          "usage" => %{"exhausted" => true, "resets_at" => far, "account_ref" => "acct-a"}
        })

      assert_reply ref, :ok, _, reply_timeout()

      stored = row(ctx.runner)
      assert_in_delta seconds_from_now(stored.usage_exhausted_until), @eight_days, 5
      assert stored.account_ref == "acct-a"

      # And NOT in the meta: the pool's `usage_exhausted_until` is read from Postgres, and a
      # copy here would be a second answer nothing decides on. The message's other fields
      # still reach the meta.
      assert [meta] = Runners.live_metas(ctx.tenant.id, ctx.runner.id)
      refute Map.has_key?(meta, :usage)
      assert meta.in_flight == 1
    end

    # A reset inside the clamp is stored AS SENT, and an ISO 8601 instant with no fraction
    # parses to second precision. Written unnormalised into the microsecond column it raised
    # an ArgumentError in this channel's process — the socket every session on the machine
    # shares — and the exhaustion was never recorded: the fail-open direction.
    test "an in-window reset with no fractional seconds is stored as sent", ctx do
      in_window =
        DateTime.utc_now() |> DateTime.add(2 * 3_600, :second) |> DateTime.truncate(:second)

      ref =
        push(ctx.channel, "status", %{
          "usage" => %{"exhausted" => true, "resets_at" => DateTime.to_iso8601(in_window)}
        })

      assert_reply ref, :ok, _, reply_timeout()
      assert DateTime.compare(row(ctx.runner).usage_exhausted_until, in_window) == :eq
    end

    # A status carrying ONLY `usage` changes nothing in the meta, so it broadcasts no Presence
    # diff: each one is a message to every node's pool subscribers for nothing.
    # Read off the channel's `presence_ref`, which every `Presence.update/4` re-issues: the
    # pool topic's own diffs are batched by the tracker, so the JOIN's diff can land at any
    # point in a receive window and cannot tell an update apart from it.
    test "a usage-only status updates no Presence meta", ctx do
      before = presence_ref(ctx.channel)

      ref = push(ctx.channel, "status", %{"usage" => %{"exhausted" => false}})
      assert_reply ref, :ok, _, reply_timeout()

      assert presence_ref(ctx.channel) == before
    end

    test "exhausted with no reset holds for eight days (TC-44.6.3)", ctx do
      {raw, other} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "beelink"})
      channel = join_as(other, raw, "beelink")

      ref = push(channel, "status", %{"usage" => %{"exhausted" => true}})
      assert_reply ref, :ok, _, reply_timeout()

      assert_in_delta seconds_from_now(row(other).usage_exhausted_until), @eight_days, 5
      # Only the reporting machine: the other has no account to share.
      assert row(ctx.runner).usage_exhausted_until == nil
    end

    test "exhausted: false from one machine clears the whole account (TC-44.6.6)", ctx do
      {raw, r2} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "beelink"})

      :ok = Usage.record(ctx.tenant.id, ctx.runner.id, %{exhausted: true, account_ref: "a"})
      :ok = Usage.record(ctx.tenant.id, r2.id, %{exhausted: true, account_ref: "a"})

      channel = join_as(r2, raw, "beelink")

      ref =
        push(channel, "status", %{"usage" => %{"exhausted" => false, "account_ref" => "a"}})

      assert_reply ref, :ok, _, reply_timeout()

      assert row(ctx.runner).usage_exhausted_until == nil
      assert row(r2).usage_exhausted_until == nil
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  # Read through the SAME connection the channel wrote on: the channel's `Loopctl.Repo` is the
  # test's sandbox connection, so its write is visible here and nowhere else until the sandbox
  # rolls it back.
  defp row(runner) do
    {:ok, row} =
      Loopctl.Repo.with_tenant(runner.tenant_id, fn -> Loopctl.Repo.get!(Runner, runner.id) end)

    row
  end

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second)

  defp presence_ref(channel), do: :sys.get_state(channel.channel_pid).assigns.presence_ref

  defp join_as(runner, raw, machine) do
    {:ok, socket} = connect_runner_socket(raw)

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, runner_join_payload(machine))

    _ = :sys.get_state(channel.channel_pid)
    channel
  end
end
