defmodule Loopctl.Test.Placement do
  @moduledoc """
  The reads and moves a `Loopctl.Delivery.Placement.place/4` test makes around a placement.

  Shared by `Loopctl.Delivery.PlacementTest` (sandboxed) and
  `Loopctl.Delivery.PlacementFaultTest` (committed, for a failure injected with DDL), so the
  two read a placement's outcome the same way. `import` it: `disconnect/2` is a macro.
  The payload and the runner socket's connect and join data are `build/2` clauses in
  `Loopctl.Fixtures`.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions, only: [flunk: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Stories
  alias Phoenix.ChannelTest

  @doc "A story contracted and standing at `queued`, which is what a placement takes."
  def contract_and_queue(tenant_id, story) do
    {:ok, story} =
      Progress.contract_story(tenant_id, story.id, %{},
        actor_label: "test",
        skip_contract_check: true
      )

    {:ok, _row} = Stages.open(tenant_id, story.id, actor_label: "test")

    epoch = story.claim_epoch
    {:ok, _} = Stages.advance(tenant_id, story.id, {:detected, :triaged}, claim_epoch: epoch)
    {:ok, _} = Stages.advance(tenant_id, story.id, {:triaged, :queued}, claim_epoch: epoch)

    story
  end

  @doc "The story's session dispatch: a placement mints exactly one."
  def session_dispatch(tenant_id, story_id) do
    AdminRepo.one!(
      from d in Dispatch, where: d.tenant_id == ^tenant_id and d.story_id == ^story_id
    )
  end

  def reload(tenant_id, story_id) do
    {:ok, story} = Stories.get_story(tenant_id, story_id)
    story
  end

  @doc "The story's `story_stage_claimed` chain entry."
  def claimed_entry(tenant_id, story_id) do
    AdminRepo.one!(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^story_id,
        where: e.action == "story_stage_claimed"
    )
  end

  @doc """
  The story's escalation STAGE EVENTS, oldest first. The stage event rather than the chain
  entry, because `actor_label` is a column on `story_stage_events` and is not on a chain entry
  at all.
  """
  def escalation_events(tenant_id, story_id) do
    AdminRepo.all(
      from e in StageEvent,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
        where: e.to_stage == "escalated",
        order_by: e.inserted_at
    )
  end

  @doc """
  Leaves the runner's channel and waits for its presence to go.

  Unlinked first: `leave/1` shuts the channel down with `{:shutdown, :left}`, and
  `subscribe_and_join/3` linked it to the test process, so the exit would take the test with
  it before a single assertion ran. A macro so the `Phoenix.ChannelTest` call expands in the
  test module rather than in a support function dialyzer checks.
  """
  defmacro disconnect(channel, runner) do
    quote do
      channel = unquote(channel)
      Process.unlink(channel.channel_pid)
      ChannelTest.leave(channel)
      unquote(__MODULE__).wait_until_disconnected(unquote(runner))
    end
  end

  @doc """
  Presence untracks when the channel process EXITS, which happens after `leave/1` returns, so
  this polls rather than asserting once. It needs a real pause between attempts: a tight
  recursion spent all fifty in well under a millisecond and flaked roughly one run in four.
  """
  def wait_until_disconnected(runner, attempts \\ 100) do
    cond do
      Loopctl.Runners.live_metas(runner.tenant_id, runner.id) == [] ->
        :ok

      attempts == 0 ->
        flunk("the runner's presence entry never went away")

      true ->
        Process.sleep(20)
        wait_until_disconnected(runner, attempts - 1)
    end
  end
end
