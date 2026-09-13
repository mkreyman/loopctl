defmodule Loopctl.Delivery.RunnerStagesTest do
  @moduledoc """
  Issue #803, contract 1.4.0: a runner's `stage` message advances the story's delivery stage
  row, is fenced on the claim epoch, is safe to replay, and gives the session's runner slot
  back exactly once when it reports a terminal outcome.

  Everything this path touches — the story, its stage row, the dispatch ledger row and the
  `runners` row whose `in_flight` the release decrements — lives on the RLS `Loopctl.Repo`
  sandbox connection, so this module is `async: true` and commits nothing. The channel
  wiring, which needs a socket and therefore a committed runner, is in
  `LoopctlWeb.RunnerChannelStageTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner

  setup :verify_on_exit!

  @epoch 4

  # The member of `Loopctl.Delivery.Stages.advance_error/0` this file asserts about.
  # `LoopctlWeb.RunnerChannel.RefusalTest` holds the full list against the type's own source.
  @advance_errors [:audit_chain_append_failed]

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  # A story at `stage`, claimed at `@epoch`, with an accepted dispatch on a runner holding
  # one slot for it.
  defp session(stage, opts \\ []) do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})

    row =
      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: stage,
        claim_epoch: @epoch,
        escalation_reason: if(stage == :escalated, do: "why")
      })

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: story.tenant_id,
        runner: runner,
        story_id: story.id,
        claim_epoch: Keyword.get(opts, :dispatch_epoch, @epoch)
      })

    %{story: story, runner: runner, row: row, record: record}
  end

  defp message(record, attrs) do
    Map.merge(
      %{
        dispatch_id: record.dispatch_id,
        claim_epoch: record.claim_epoch,
        edge: :forward
      },
      Map.new(attrs)
    )
  end

  defp in_flight(runner),
    do: as_tenant(runner.tenant_id, fn -> Repo.get!(Runner, runner.id) end).in_flight

  defp released?(record) do
    as_tenant(record.tenant_id, fn ->
      Repo.one(
        from d in DispatchRecord, where: d.id == ^record.id, select: not is_nil(d.released_at)
      )
    end)
  end

  defp chain_actions(tenant_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id,
          order_by: [asc: e.chain_position],
          select: e.action
      )
    end)
  end

  defp transition_events(tenant_id, story_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in StageEvent,
          where:
            e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.event == "transitioned",
          order_by: [asc: e.inserted_at, asc: e.lock_version]
      )
    end)
  end

  describe "apply/3" do
    test "advances the row and records the effects the transition carried" do
      %{story: story, runner: runner, record: record} = session(:worktree)

      assert {:ok, row} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :worktree, to: :implementing, effects: %{}})
               )

      assert row.stage == :implementing
      assert row.claim_epoch == @epoch

      sha = String.duplicate("a", 40)

      assert {:ok, row} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{
                   from: :implementing,
                   to: :reviewing,
                   effects: %{head_sha: sha}
                 })
               )

      assert row.stage == :reviewing
      assert row.head_sha == sha
    end

    test "refuses a message whose epoch is not the dispatch's, before any write" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert {:error, :stale_claim_epoch} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing, claim_epoch: @epoch + 1})
               )

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "refuses a message whose epoch is the dispatch's but no longer the STORY's" do
      # The claim was reclaimed under a session that kept working: the ledger row still
      # carries the old epoch, so only the story's own epoch, read inside the transition,
      # can catch it.
      %{story: story, runner: runner, record: record} = session(:implementing)

      as_tenant(story.tenant_id, fn ->
        from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [claim_epoch: @epoch + 1])
      end)

      assert {:error, :stale_claim_epoch} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "refuses a dispatch this runner does not hold, and one that is not accepted" do
      %{story: story, runner: runner, record: record} = session(:implementing)
      other = fixture(:stage_runner, %{tenant_id: story.tenant_id})

      assert {:error, :unknown_dispatch} =
               RunnerStages.apply(
                 story.tenant_id,
                 other.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )

      as_tenant(story.tenant_id, fn ->
        from(d in DispatchRecord, where: d.id == ^record.id)
        |> Repo.update_all(set: [status: "superseded"])
      end)

      assert {:error, :dispatch_not_accepted} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )
    end

    test "a replayed message is answered with the row and transitions nothing twice" do
      %{story: story, runner: runner, record: record} = session(:implementing)
      msg = message(record, %{from: :implementing, to: :reviewing})

      assert {:ok, first} = RunnerStages.apply(story.tenant_id, runner.id, msg)
      assert {:ok, second} = RunnerStages.apply(story.tenant_id, runner.id, msg)

      assert second.stage == :reviewing
      assert second.lock_version == first.lock_version
      assert length(transition_events(story.tenant_id, story.id)) == 1
    end

    test "a replay naming a DIFFERENT identity is refused, not answered ok" do
      # #824 round 2, finding 2. The merge is the case that forces it: `ci -> merged` with
      # merge_sha A commits, the ack is lost, the runner retries and its retry names merge
      # commit B. Answered `ok`, the row and the `story_stage_merged` chain entry keep A, B
      # is dropped silently, and the CHAIN NAMES A MERGE THAT IS NOT THE BRANCH'S.
      %{story: story, runner: runner, record: record} = session(:ci)
      sha_a = String.duplicate("a", 40)
      sha_b = String.duplicate("b", 40)

      first =
        message(record, %{from: :ci, to: :merged, effects: %{merge_sha: sha_a}})

      assert {:ok, row} = RunnerStages.apply(story.tenant_id, runner.id, first)
      assert row.merge_sha == sha_a

      # The SAME value again is the real replay and is still fine.
      assert {:ok, same} = RunnerStages.apply(story.tenant_id, runner.id, first)
      assert same.merge_sha == sha_a

      # A different one is not a replay at all — and the refusal CARRIES the sha that
      # survived, because the case it exists for is a LOST ack: the runner never saw the one
      # that named it (#824 round 3, finding 4).
      assert {:error, {:effect_conflict, recorded}} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :ci, to: :merged, effects: %{merge_sha: sha_b}})
               )

      assert recorded.merge_sha == sha_a
      assert Stages.get(story.tenant_id, story.id).merge_sha == sha_a
    end

    test "a replay supplying an identity the row does not hold is refused" do
      # The row is at the destination WITHOUT that identity, so this is a different message
      # that happens to share a stage. Accepting it would attach an effect after the chain
      # entry that should have named it.
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert {:ok, _} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )

      # The refusal names what the row holds — here, nothing, which is the answer.
      assert {:error, {:effect_conflict, recorded}} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{
                   from: :implementing,
                   to: :reviewing,
                   effects: %{head_sha: String.duplicate("c", 40)}
                 })
               )

      refute Map.has_key?(recorded, :head_sha)
      assert is_nil(Stages.get(story.tenant_id, story.id).head_sha)
    end

    test "a zombie whose claim was reclaimed writes nothing on a re-send" do
      %{story: story, runner: runner, record: record} = session(:implementing)
      msg = message(record, %{from: :implementing, to: :reviewing})

      assert {:ok, _} = RunnerStages.apply(story.tenant_id, runner.id, msg)

      as_tenant(story.tenant_id, fn ->
        from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [claim_epoch: @epoch + 1])
      end)

      assert {:error, :stale_claim_epoch} = RunnerStages.apply(story.tenant_id, runner.id, msg)
    end

    test "a dispatch whose epoch is behind the STORY's cannot report, even at the story's" do
      # The one case only the dispatch-epoch pre-check catches, and the reason it is not
      # redundant with the fence inside the transition: this dispatch served an EARLIER
      # claim (its row still says so) while the story has been claimed again. A message
      # carrying the story's CURRENT epoch would sail through that fence — the epoch it
      # presents is right — and land a transition on behalf of a session whose dispatch is
      # stale. The check is against the dispatch this runner actually holds.
      %{story: story, runner: runner, record: record} =
        session(:implementing, dispatch_epoch: @epoch - 1)

      assert record.claim_epoch == @epoch - 1

      assert {:error, :stale_claim_epoch} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing, claim_epoch: @epoch})
               )

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "a message for a row that moved somewhere ELSE is stale_stage, not a replay" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert {:ok, _} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )

      # A perfectly legal transition, sent by a runner two stages ahead of the row.
      assert {:error, :stale_stage} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :pr_open, to: :ci})
               )
    end

    test "a transition the machine does not have is refused as a message fault" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert {:error, {:invalid, ["invalid_transition"]}} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :merged})
               )
    end

    test "entering escalated without a reason is refused as a message fault" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert {:error, {:invalid, ["reason_required"]}} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{
                   from: :implementing,
                   to: :escalated,
                   edge: :session_escalated
                 })
               )
    end

    test "a story with no stage row is unknown_story_stage, not unknown_dispatch" do
      story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
      runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})

      record =
        fixture(:accepted_dispatch, %{
          tenant_id: story.tenant_id,
          runner: runner,
          story_id: story.id,
          claim_epoch: @epoch
        })

      assert {:error, :unknown_story_stage} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )
    end
  end

  describe "session end" do
    test "a terminal outcome releases exactly one slot, and a replay releases no second" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert in_flight(runner) == 1
      refute released?(record)

      msg =
        message(record, %{
          from: :implementing,
          to: :escalated,
          edge: :session_escalated,
          reason: "the request contradicts US-3.1"
        })

      assert {:ok, row} = RunnerStages.apply(story.tenant_id, runner.id, msg)
      assert row.stage == :escalated
      assert row.escalation_reason == "the request contradicts US-3.1"
      assert in_flight(runner) == 0
      assert released?(record)

      # The replay resolves to the same row and the counter does not go negative.
      assert {:ok, replayed} = RunnerStages.apply(story.tenant_id, runner.id, msg)
      assert replayed.stage == :escalated
      assert in_flight(runner) == 0
    end

    test "the SUCCESS path releases the slot: the session ends at the deploy" do
      # #824 round 3, H1. With the runner's source filter stopping at `merged`, `deployed` is
      # the last thing a session reports — and `deployed` is not terminal, so while the
      # release keyed on the terminals alone a SUCCESSFUL run released nothing inline. Its
      # slot then waited out `heal/3`'s wall-clock bound, which is the dispatch's whole
      # budget: a ten-minute session held a slot for an hour and a two-session machine sat at
      # capacity for the rest of it. The only inline release a runner could trigger was the
      # FAILURE path.
      %{story: story, runner: runner, record: record} = session(:merged)

      assert in_flight(runner) == 1

      assert {:ok, row} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :merged, to: :deployed})
               )

      assert row.stage == :deployed
      assert in_flight(runner) == 0
      assert released?(record)
    end

    test "a replay of the deploy releases no second slot" do
      %{story: story, runner: runner, record: record} = session(:merged)
      msg = message(record, %{from: :merged, to: :deployed})

      assert {:ok, _} = RunnerStages.apply(story.tenant_id, runner.id, msg)
      assert in_flight(runner) == 0

      assert {:ok, replayed} = RunnerStages.apply(story.tenant_id, runner.id, msg)
      assert replayed.stage == :deployed
      assert in_flight(runner) == 0
    end

    test "a NON-terminal transition releases nothing, even carrying a live dispatch" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      assert {:ok, _} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{from: :implementing, to: :reviewing})
               )

      assert in_flight(runner) == 1
      refute released?(record)
    end

    test "a replay of a terminal message releases a slot the FIRST copy did not" do
      # The escalate ENDPOINT holds no runner dispatch id, so a session that escalated
      # through it leaves the slot held; the runner's own `stage` message for the same
      # transition is what gives it back, and that message arrives as a replay.
      %{story: story, runner: runner, record: record, row: row} = session(:implementing)

      assert {:ok, _} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {row.stage, :escalated, :session_escalated},
                 claim_epoch: @epoch,
                 reason: "a human is needed",
                 actor_role: :agent,
                 actor_lineage: []
               )

      assert in_flight(runner) == 1

      assert {:ok, replayed} =
               RunnerStages.apply(
                 story.tenant_id,
                 runner.id,
                 message(record, %{
                   from: :implementing,
                   to: :escalated,
                   edge: :session_escalated,
                   reason: "a human is needed"
                 })
               )

      assert replayed.stage == :escalated
      assert in_flight(runner) == 0
      assert released?(record)
    end

    test "the escalation is on the audit chain, once" do
      %{story: story, runner: runner, record: record} = session(:implementing)

      msg =
        message(record, %{
          from: :implementing,
          to: :escalated,
          edge: :session_escalated,
          reason: "needs a business call"
        })

      assert {:ok, _} = RunnerStages.apply(story.tenant_id, runner.id, msg)
      assert {:ok, _} = RunnerStages.apply(story.tenant_id, runner.id, msg)

      assert chain_actions(story.tenant_id) == ["story_stage_escalated"]
    end
  end

  describe "a refused chain append is permanent" do
    test "classify/1 does not reclassify it as retryable" do
      # #824 round 3, finding 5. It used to map to `:busy`, which reaches the runner as
      # `rate_limited` — a RETRY instruction against a deterministic failure that will refuse
      # the next attempt identically, while every custody transition in the tenant is failing
      # until an operator acts. The HTTP surface answers 500 for the same condition and says
      # retrying will not help; one condition must not carry opposite advice.
      #
      # A source assertion because the branch is unreachable from a test: making a tenant's
      # hash chain refuse an append needs a broken chain, and `LoopctlWeb.RunnerChannel.Refusal`
      # already carries the FORMAT of the refusal under its own falsifiable test. What is left
      # to bind is only that nothing intercepts the atom on its way there.
      code =
        "lib/loopctl/delivery/runner_stages.ex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
        |> Enum.join("\n")

      refute code =~ "classify(:audit_chain_append_failed)",
             "a refused chain append must pass through to Refusal as its own permanent code, " <>
               "never be reclassified as retryable"

      # And the atom really is in the set that reaches here, so the assertion is about a
      # reachable value rather than a hypothetical one.
      assert :audit_chain_append_failed in @advance_errors
    end
  end

  describe "tenant isolation" do
    test "a runner cannot report a stage for another tenant's dispatch" do
      a = session(:implementing)
      b = session(:implementing)

      # b's runner id against a's tenant: the ownership predicate is (tenant, runner), so
      # this is indistinguishable from a dispatch that does not exist.
      assert {:error, :unknown_dispatch} =
               RunnerStages.apply(
                 a.story.tenant_id,
                 b.runner.id,
                 message(a.record, %{from: :implementing, to: :reviewing})
               )

      # and a's runner reaching into b's tenant sees nothing either.
      assert {:error, :unknown_dispatch} =
               RunnerStages.apply(
                 b.story.tenant_id,
                 a.runner.id,
                 message(a.record, %{from: :implementing, to: :reviewing})
               )

      assert Stages.get(a.story.tenant_id, a.story.id).stage == :implementing
      assert Stages.get(b.story.tenant_id, b.story.id).stage == :implementing
    end
  end
end
