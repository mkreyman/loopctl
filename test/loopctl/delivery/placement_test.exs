defmodule Loopctl.Delivery.PlacementTest do
  @moduledoc """
  Issue #803: the dispatch claims the story it is sent for.

  `async: false`, and COMMITTED rather than sandboxed, for a reason that is a fact about the
  code under test rather than a convenience. A placement spans BOTH repos — the claim is an
  `AdminRepo` transaction (`Loopctl.Progress.claim_story/3`) and the `queued -> claimed`
  transition is a `Loopctl.Repo` one, because `Loopctl.AuditChain.append_in_tenant_transaction/2`
  raises outside a `Repo` transaction and that transition is chained. The two sandbox
  connections cannot see each other's uncommitted work, and worse, the claim's UPDATE holds
  the story row, so the transition's `FOR SHARE` would sit on it until its `lock_timeout`.
  Everything the placement touches is therefore committed, and
  `sweep_committed_runner_tenants/0` removes it — chain entries included.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.AuditChain
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.ImplementerInput
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000

  setup do
    # HUMAN-ANCHORED explicitly: `place/4` applies the L0 tier gate itself, and the committed
    # tenant's column default is `:agent_rooted`.
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    {_operator_raw, operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(raw))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)

    # `fixture(:committed_story)` checks out its OWN unboxed connection, so it is called
    # OUTSIDE `unboxed/1`: nesting two `unboxed_run`s on `Loopctl.Repo` checks the connection
    # back in at the inner block's end, and the rest of the setup would then run on the SHARED
    # SANDBOX connection — whose transaction never commits, so the `FOR SHARE` a stage
    # transition takes would hold the story row for the whole test and the claim would sit on
    # it until its lock timeout.
    story = fixture(:committed_story, %{tenant_id: runner.tenant_id})
    story = unboxed(fn -> contract_and_queue(runner.tenant_id, story) end)

    %{runner: runner, channel: channel, story: story, operator: operator, runner_key: raw}
  end

  describe "place/4" do
    test "the dispatch carries the story object loopctl built from its own row", ctx do
      %{runner: runner, story: story} = ctx

      # Real acceptance criteria on the ROW, because they are what an implementer is judged
      # against and what the fixture story does not have: without them the object is a title
      # and an id, and this test would pass on a dispatch carrying no work either.
      unboxed(fn -> give_criteria!(runner.tenant_id, story.id) end)
      story = unboxed(fn -> reload(runner.tenant_id, story.id) end)

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", pushed, @reply_timeout

      # The whole point of the dispatch, and it was MISSING: an implement dispatch carries the
      # story as typed fields and the runner composes its prompt from them, so a dispatch with
      # no `story` names a story_id and carries no work. The runner refuses it outright and
      # identically on every redispatch — a clean, permanent, invisible no — which is what
      # both callers of this function sent until now.
      assert pushed.story.id == story.id
      assert pushed.story.title == story.title

      # Built from POSTGRES, not echoed from the caller: the criteria are the story's own.
      assert pushed.story.acceptance_criteria == expected_criteria(story)
    end

    test "the repo, base branch and branch are FILLED from loopctl's own records", ctx do
      %{runner: runner, story: story} = ctx
      source = unboxed(fn -> bind_repo(runner.tenant_id, story, "mkreyman/home_care_billing") end)

      # `RunnerDispatch` requires `repo`, `branch`, `base_branch` and both budgets, and
      # `cast_dispatch/1` applies no defaults — but that cast is the FIRST step of
      # `Runners.dispatch/3`, which runs after the mint, the claim and two IMMUTABLE chain
      # entries. So a caller that omitted one paid for all of that and got a 422. Each is
      # something loopctl can look up, so it does, before anything is written.
      #
      # The budgets are PASSED here because the test environment configures neither, which is
      # the next test.
      minimal = %{
        "dispatch_id" => Ecto.UUID.generate(),
        "story_id" => story.id,
        "kind" => "implement",
        "wall_clock_seconds" => 3_600,
        "max_turns" => 50
      }

      assert {:ok, _placed} = place(ctx, minimal)
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.repo == source.repo_full_name
      assert pushed.base_branch == source.base_branch
      assert pushed.branch == "feature/story-#{story.number}-#{String.slice(story.id, 0, 8)}"
    end

    test "a budget nobody configured is named BEFORE anything is minted", ctx do
      %{runner: runner, story: story} = ctx
      unboxed(fn -> bind_repo(runner.tenant_id, story, "mkreyman/cron_books") end)

      minimal = %{
        "dispatch_id" => Ecto.UUID.generate(),
        "story_id" => story.id,
        "kind" => "implement"
      }

      # NO DEFAULT is the policy — a budget is a cost decision loopctl does not make for an
      # operator — so this is configuration rather than a bad request, and the refusal names
      # the key. Before anything is minted, which is the difference from letting the contract
      # refuse it: nothing is claimed and no chain entry is written.
      assert {:error, {:unset, :dispatch_wall_clock_seconds}} = place(ctx, minimal)
      refute_push "dispatch", _pushed

      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :queued
      assert unboxed(fn -> reload(runner.tenant_id, story.id) end).agent_status == :contracted
    end

    test "a CALLER-supplied story object is refused, and nothing is claimed", ctx do
      %{runner: runner, story: story} = ctx

      payload =
        Map.put(dispatch_payload(story), "story", build(:runner_story, %{"id" => story.id}))

      # The contract's no-prompt rule, holding one level along: a caller able to hand a runner
      # an arbitrary story object is a caller able to hand it prose to execute, and a dispatch
      # runs as the machine's user. Refused in `place/4` and not only at the HTTP edge,
      # because a worker, an MCP tool and the unattended driver never pass through that edge.
      assert {:error, :story_not_accepted} = place(ctx, payload)
      refute_push "dispatch", _pushed

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :queued
      assert unboxed(fn -> reload(runner.tenant_id, story.id) end).agent_status == :contracted
    end

    test "a story too large for the contract is ESCALATED, and the claim goes back", ctx do
      %{runner: runner, story: story} = ctx

      # Oversize by the contract's own byte rule, which charges 6 bytes per character. loopctl
      # REFUSES such a story rather than truncating it — a dropped acceptance criterion is a
      # story built to the wrong spec and an implementer cannot tell three criteria from four
      # with the fourth cut.
      unboxed(fn -> oversize!(runner.tenant_id, story.id) end)

      assert {:error, {:story_not_dispatchable, [_ | _]}} = place(ctx, dispatch_payload(story))
      refute_push "dispatch", _pushed

      # ESCALATED, not requeued, and both halves matter. The escalation is where the builder
      # put the story — a human has it — and `undo_claim/5` must not fight that:
      # `Stages.follow_release/5` requeues only an IN-FLIGHT row and rebinds anything else, so
      # the row keeps `escalated` and takes the released epoch rather than going back to
      # `queued` for the next pass to fail on identically.
      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :escalated

      # And the claim is released: no session will ever run under it.
      released = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert released.assigned_agent_id == nil
      assert released.claim_epoch > story.claim_epoch
      assert row.claim_epoch == released.claim_epoch
    end

    test "claims the story, enters `claimed` and pushes the dispatch", ctx do
      %{runner: runner, story: story} = ctx
      payload = dispatch_payload(story)

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.dispatch_id == payload["dispatch_id"]
      assert pushed.claim_epoch == placed.claim_epoch

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert claimed.agent_status == :assigned
      assert claimed.assigned_agent_id == runner.agent_id
      assert claimed.implementer_dispatch_id == placed.implementer_dispatch_id
      assert claimed.claim_epoch == placed.claim_epoch
      assert claimed.claim_epoch > story.claim_epoch

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :claimed
      assert row.runner_id == runner.id
      assert row.claim_epoch == placed.claim_epoch
    end

    test "the claim's chain entry is attributed to the dispatch it minted", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      session = unboxed(fn -> AdminRepo.get!(Dispatch, placed.implementer_dispatch_id) end)
      entry = unboxed(fn -> claimed_entry(runner.tenant_id, story.id) end)

      # Not `[]`, and not anything this path invented: the lineage of a dispatch row that was
      # really minted, rooted where the CALLER's own lineage put it.
      assert entry.actor_lineage == session.lineage_path
      assert session.lineage_path != []
      assert session.agent_id == runner.agent_id
      assert session.story_id == story.id
      assert session.role == :agent
    end

    test "the session dispatch lands inside the caller's OWN subtree, resolved from its key",
         ctx do
      %{runner: runner, story: story} = ctx
      %{dispatch: parent, api_key: parent_key} = unboxed(fn -> orchestrator(runner.tenant_id) end)

      assert {:ok, placed} = place(ctx, dispatch_payload(story), api_key: parent_key)
      assert_push "dispatch", _pushed, @reply_timeout

      session = unboxed(fn -> AdminRepo.get!(Dispatch, placed.implementer_dispatch_id) end)
      assert session.parent_dispatch_id == List.last(parent.lineage_path)
      assert List.starts_with?(session.lineage_path, parent.lineage_path)

      # Nothing named that parent: it was derived from the key the caller authenticated with.
      # `place/4` takes no lineage option at all, which is what makes "inside the CALLER's
      # subtree" a property rather than a restatement of what the caller asked for.
      assert Dispatches.lineage_for_api_key(runner.tenant_id, parent_key.id) ==
               parent.lineage_path
    end

    test "an unlineaged caller below :user may not start a tree, and claims nothing", ctx do
      %{runner: runner, story: story, runner_key: raw} = ctx

      # The RUNNER's own key: role `:agent`, minted by no dispatch, so its resolved lineage is
      # `[]`. Realistic rather than contrived — it is the credential nearest to hand for
      # anything running on the machine the dispatch would start a session on.
      {:ok, runner_api_key} = unboxed(fn -> Loopctl.Auth.verify_api_key(raw) end)

      assert {:error, :root_dispatch_forbidden} =
               place(ctx, dispatch_payload(story), api_key: runner_api_key)

      refute_push "dispatch", _pushed, 200

      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :queued
      assert unboxed(fn -> session_dispatch_count(runner.tenant_id, story.id) end) == 0
    end

    test "a key from another tenant is not authorized, whatever its role", ctx do
      %{story: story} = ctx
      other = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      {_raw, intruder} = fixture(:committed_operator_key, %{tenant_id: other.id})

      assert {:error, :not_authorized} =
               place(ctx, dispatch_payload(story), api_key: intruder)

      refute_push "dispatch", _pushed, 200
    end

    test "an agent_rooted tenant is refused the whole path, and claims nothing", ctx do
      # The L0 gate, applied in the context because no plug can reach here. Both halves of
      # what this path does — minting a custody dispatch and driving a chained custody
      # transition — are human-anchored on the HTTP surface.
      %{runner: runner, story: story} = ctx
      unboxed(fn -> set_trust_tier(runner.tenant_id, :agent_rooted) end)

      assert {:error, :custody_tier_required} = place(ctx, dispatch_payload(story))

      refute_push "dispatch", _pushed, 200

      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert unboxed(fn -> session_dispatch_count(runner.tenant_id, story.id) end) == 0
    end

    test "a halted tenant is refused the whole path, and nothing is minted or claimed", ctx do
      # L6. `CheckCustodyHalt` is a pipeline plug and there is no `conn` here;
      # `Runners.dispatch/3`'s own halt check runs at the PUSH, after the mint and after both
      # commits. And the usual backstop does not apply — `ReclaimExpiredClaimsWorker` skips
      # halted tenants — so a claim left standing on one is never reclaimed.
      %{runner: runner, story: story} = ctx
      before = unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end)
      unboxed(fn -> halt_custody(runner.tenant_id) end)

      assert {:error, :tenant_halted} = place(ctx, dispatch_payload(story))
      refute_push "dispatch", _pushed, 200

      assert unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end) == before
      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
      assert unboxed(fn -> chain_entry_count(runner.tenant_id) end) == 0
    end

    test "a lineaged caller below :orchestrator may not mint at all", ctx do
      # `DispatchController` mounts `RequireRole, role: :orchestrator` on `:create` and
      # `create_dispatch/3` has no role gate of its own, so without this an AGENT-role key that
      # some dispatch minted could mint a child custody dispatch and a live ephemeral key
      # through a path the HTTP surface 403s.
      %{runner: runner, story: story} = ctx
      %{api_key: agent_key} = unboxed(fn -> lineaged_agent(runner.tenant_id) end)
      before = unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end)

      assert {:error, :insufficient_role} =
               place(ctx, dispatch_payload(story), api_key: agent_key)

      refute_push "dispatch", _pushed, 200
      assert unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end) == before
      assert unboxed(fn -> reload(runner.tenant_id, story.id) end).agent_status == :contracted
    end

    test "a story that is not ready is refused BEFORE anything is minted", ctx do
      %{runner: runner, story: story} = ctx
      before = unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end)

      # Its stage row is at `queued`, but the story itself is back at `pending`.
      unboxed(fn -> Progress.force_unclaim_story(runner.tenant_id, story.id, []) end)

      assert {:error, :invalid_transition} = place(ctx, dispatch_payload(story))

      # The point of the pre-check: a loop over an unready story writes no `dispatches` row,
      # no ephemeral key and no immutable chain entry, and takes the tenant's chain advisory
      # lock zero times.
      assert unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end) == before
      refute_push "dispatch", _pushed, 200
    end

    test "a stage row that is not at `queued` is refused before anything is minted", ctx do
      %{runner: runner} = ctx
      before = unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end)

      # A second story, CONTRACTED but left at `detected` — the story half of the readiness
      # check passes and the stage half does not, so this pins the stage half on its own.
      early = fixture(:committed_story, %{tenant_id: runner.tenant_id})

      early =
        unboxed(fn ->
          {:ok, contracted} =
            Progress.contract_story(runner.tenant_id, early.id, %{},
              actor_label: "test",
              skip_contract_check: true
            )

          {:ok, _row} = Stages.open(runner.tenant_id, early.id, actor_label: "test")
          contracted
        end)

      assert unboxed(fn -> Stages.get(runner.tenant_id, early.id) end).stage == :detected
      assert {:error, :wrong_stage} = place(ctx, dispatch_payload(early))
      assert unboxed(fn -> tenant_dispatch_count(runner.tenant_id) end) == before
    end

    test "a claim that fails past the pre-check REVOKES the dispatch it minted", ctx do
      %{runner: runner, story: story} = ctx

      # The race `claimable/2` cannot close, made deterministic. An unmet story dependency is
      # invisible to the pre-check — the story is `contracted` and its stage row is at `queued`
      # — and `claim_story/3` refuses it. That is the one path on which a dispatch is minted
      # for a claim that never happens, so its ephemeral key must not be left live for its
      # four-hour TTL with no session to use it and nothing else to revoke it.
      blocker = fixture(:committed_story, %{tenant_id: runner.tenant_id})

      unboxed(fn ->
        fixture(:story_dependency, %{
          tenant_id: runner.tenant_id,
          story_id: story.id,
          depends_on_story_id: blocker.id
        })
      end)

      assert {:error, :dependencies_not_met} = place(ctx, dispatch_payload(story))
      refute_push "dispatch", _pushed, 200

      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)
      assert session.revoked_at, "the minted dispatch was left live for a claim that failed"
      assert unboxed(fn -> AdminRepo.get!(ApiKey, session.api_key_id) end).revoked_at

      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert is_nil(untouched.implementer_dispatch_id)
    end

    test "a dispatch_id is spent by the claim it was placed under", ctx do
      %{runner: runner, story: story} = ctx
      payload = dispatch_payload(story)

      assert {:ok, _first} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      # The claim ends — an operator force-unclaims — so the ledger row's epoch is now a claim
      # that does not exist. Re-placing the SAME dispatch_id can never work again, which is the
      # fence doing its job and the reason `place/4`'s doc says a re-place needs a new id.
      unboxed(fn -> Progress.force_unclaim_story(runner.tenant_id, story.id, []) end)

      assert {:error, :stale_claim_epoch} = place(ctx, payload)
    end

    test "a RESUME rebuilds the story object, and refuses rather than re-sending without one",
         ctx do
      %{runner: runner, story: story, channel: channel} = ctx
      payload = dispatch_payload(story)

      assert {:ok, _first} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      # The retry path pushed the CALLER's map, which since `no_caller_story/1` can never
      # carry a story — so a re-send (a lost HTTP response, a failed broadcast, a dropped
      # frame; each leaves the ledger row at `sent`, which is what routes a re-send here) put
      # an implement dispatch with no story on the wire while this function answered `{:ok,
      # ...}` as though work had been placed. That is the very defect this change exists to
      # fix, left open on the ordinary retry path.
      #
      # Proven by making the STORY undispatchable between the two calls: the resume can only
      # answer this if it actually built the object. Without the rebuild it reaches the push
      # and answers `:runner_not_connected` instead, which is what the test below asserts for
      # a story that is still fine.
      disconnect(channel, runner)
      unboxed(fn -> oversize!(runner.tenant_id, story.id) end)

      assert {:error, {:story_no_longer_dispatchable, [_ | _]}} = place(ctx, payload)

      # AND NOTHING WAS WRITTEN. A re-send does not own the claim it would be parking — the
      # story may be live under a session right now — and the ledger's own fences
      # (`dispatch_already_replied`, `stale_claim_epoch`) are not reached until the PUSH, so
      # escalating here would have written over a story nobody asked about, for a duplicate
      # retry of a dispatch that was already answered. Round 2 of this PR's review caught it.
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :claimed
      still = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert still.agent_status == :assigned
      assert still.assigned_agent_id == runner.agent_id
    end

    test "an upper-case story_id is placed, and the object matches the id on the wire", ctx do
      %{runner: runner, story: story} = ctx
      shouty = String.upcase(story.id)
      payload = Map.put(dispatch_payload(story), "story_id", shouty)

      # `Ecto.UUID.cast/1` DOWN-CASES, so the claim uses the canonical id while the caller's
      # map keeps its own spelling — and the object loopctl builds carries the ROW's id, which
      # the contract then compares against the dispatch's `story_id`. Round 1 of this PR's
      # review read that as a regression; it is not, and this test is the disproof rather than
      # a fix: `RunnerContract.cast_dispatch/1` normalises `story_id` before the comparison,
      # and `Runners.dispatch/3` broadcasts the CAST map, so the frame carries the canonical
      # id too. Kept because nothing else pinned it.
      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.story_id == story.id
      assert pushed.story.id == story.id
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :claimed
    end

    test "a re-sent dispatch_id claims nothing a second time, and releases nothing", ctx do
      %{runner: runner, story: story, channel: channel} = ctx
      payload = dispatch_payload(story)

      assert {:ok, first} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      # The runner goes away between the two placements, so the RETRY refuses at the push.
      # That is the interesting shape: the retry resumed from the ledger, so it must neither
      # claim again NOR release the claim the first placement made — a session may be running
      # under it. (That a re-send reaches the socket again is `Runners.dispatch/3`'s own
      # behaviour and is covered in `LoopctlWeb.RunnerChannelDispatchTest`; it cannot be
      # asserted here, because the channel marked the ledger row `pushed` inside the shared
      # SANDBOX transaction and that row lock is held for the rest of the test.)
      disconnect(channel, runner)

      assert {:error, :runner_not_connected} = place(ctx, payload)

      after_retry = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert after_retry.claim_epoch == first.claim_epoch
      assert after_retry.agent_status == :assigned
      assert after_retry.implementer_dispatch_id == first.implementer_dispatch_id
      assert unboxed(fn -> session_dispatch_count(runner.tenant_id, story.id) end) == 1
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :claimed

      record =
        unboxed(fn -> DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]) end)

      assert record.claim_epoch == first.claim_epoch
    end

    test "a refused push releases the claim it made", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      # The runner leaves before the dispatch is placed, so `Runners.dispatch/3` refuses
      # `:runner_not_connected` AFTER the claim has committed — the window this compensates.
      disconnect(channel, runner)

      # A COMPLETE undo says nothing. `log_undo/5` warns only when a step did not do what it
      # was for, and a warning on the ordinary compensation path would be noise that trains an
      # operator to skip the line that matters. (The FAILURE half of that log is not falsifiable
      # here — nothing in this harness can make `force_unclaim_story/3` fail — and is reported
      # as such rather than counted.)
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :runner_not_connected} = place(ctx, dispatch_payload(story))
        end)

      refute log =~ "placement undo did not fully undo"

      released = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert released.agent_status == :pending
      assert is_nil(released.assigned_agent_id)

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :queued
      assert is_nil(row.runner_id)
      assert row.claim_epoch == released.claim_epoch

      # The claim's release does NOT clear `implementer_dispatch_id` — correctly, for its own
      # callers — so the undo has to. Left recorded, the next claimant is judged against a
      # dispatch that did nothing: refused `caller_lineage_required` if unlineaged, or
      # `self_report_blocked` if its lineage shares a chain with the stale one.
      #
      # REVOKING CHANGES NEITHER OF THOSE, and an earlier version of this comment said it did.
      # `Dispatches.get_dispatch/2` has no `revoked_at` filter and `revoke/2` leaves
      # `lineage_path` intact, so a revoked recorded dispatch resolves exactly like a live one.
      # The revoke is asserted because the KEY must not stay live for its TTL with no session
      # to use it — a credential-hygiene property, not a custody-gate one.
      assert is_nil(released.implementer_dispatch_id)
      assert unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end).revoked_at
    end

    test "the undo's revocation is attributed to the PLACEMENT CALLER, not the tenant operator",
         ctx do
      # #862 review round 2, finding 3. `undo_claim/5` releases the claim FIRST, and since
      # #862 `force_unclaim_story/3` revokes the story's session dispatch itself — so the
      # `dispatch_revoked` entry on the chain is written by the RELEASE, and the explicit
      # `revoke_session_dispatch/3` that follows finds nothing left to revoke and appends
      # nothing. `Progress` reads the lineage as `Keyword.get(opts, :actor_lineage, [])`, so
      # passing only `actor_label:` recorded an agent's compensation with an EMPTY actor
      # lineage — which on the chain is the shape the tenant's own operator key writes.
      # Misattribution on an immutable, STH-covered record is worse than no record.
      #
      # PLACED BY A LINEAGED CALLER, deliberately. The default `place/4` caller here is the
      # tenant's operator key, whose resolved lineage is `[]` — so the session dispatch is a
      # ROOT, `Enum.drop(lineage_path, -1)` is `[]`, and the expected value would equal the
      # DEFECT's value. A parent dispatch is what makes the two differ, which is what makes
      # this assertion able to go red.
      #
      # Asserted against the SESSION's own lineage minus its leaf, which is what
      # `mint_session_dispatch/5` parented it on — never against a literal, so the assertion
      # cannot drift into agreeing with a hard-coded value.
      %{runner: runner, story: story, channel: channel} = ctx
      %{dispatch: parent, api_key: parent_key} = unboxed(fn -> orchestrator(runner.tenant_id) end)

      disconnect(channel, runner)

      assert {:error, :runner_not_connected} =
               place(ctx, dispatch_payload(story), api_key: parent_key)

      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)
      assert session.revoked_at

      assert [entry] = unboxed(fn -> revoked_entries(runner.tenant_id, session.id) end)
      assert entry.actor_lineage == Enum.drop(session.lineage_path, -1)
      assert entry.actor_lineage == parent.lineage_path

      refute entry.actor_lineage == [],
             "an empty actor lineage reads as the tenant operator having done this"
    end

    # 846.1. The defect is NOT that a refused dispatch parks the story — `undo_claim/5` has
    # released the claim inline since #803, and the test above proves it. It is that the
    # release can RUN AND FAIL, and until now nothing covered that: `log_undo/5` wrote a
    # warning and the story sat at `claimed`. Observed 2026-09-15, four hours.
    #
    # Most of what follows proves the ESCALATION by calling the public entry point on a story a
    # real placement left `claimed`, because no in-process harness can make
    # `Progress.force_unclaim_story/3` fail inside a live `place/4`: it performs every write in
    # one `AdminRepo` transaction and rescues its only post-commit step, so every failure mode
    # reachable from Elixir breaks the CLAIM first — which is also why the four-hour incident
    # was an outlier rather than a daily event.
    #
    # NO MOCK CAN, BUT A TRIGGER CAN, and "a release that genuinely FAILED escalates" below
    # does exactly that. Round 1 of #865 left this gap open and said so; the comment here used
    # to name `bin/mutate.sh` as what joined the two halves, which was a join that existed only
    # while somebody ran that one mutation by hand. The call site in `undo_claim/5` and the
    # two-clause condition over `release` are now asserted by a test.
    test "a release that SUCCEEDED escalates nothing", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      disconnect(channel, runner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :runner_not_connected} = place(ctx, dispatch_payload(story))
        end)

      # NEITHER escalation log line, which is one assertion covering both branches: a story
      # whose claim went back is at `queued`, and `:session_escalated` leaves
      # `@in_flight ++ [:merged, :deployed]` — `queued` is in none of them — so an escalation
      # that fired here would not move the row at all and would only be visible as the LOUD
      # "COULD NOT ESCALATE" error. Asserting on the row alone could not see it.
      refute log =~ "ESCALATE"

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :queued
      assert is_nil(row.escalation_reason)
    end

    # THE OTHER HALF OF THE SAME CONDITION, and the one that makes the call site in
    # `undo_claim/5` assertable at all: a release that RAN AND FAILED, driven through a real
    # `place/4` rather than by calling the escalation directly. Staged by DDL rather than by a
    # mock — see `fail_the_release!/1` for why nothing in Elixir can reach this state, and why
    # a trigger costs nothing in this file.
    test "a release that genuinely FAILED escalates the story, through place/4", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      fail_the_release!(story.id)
      disconnect(channel, runner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # THE CALLER STILL GETS ITS OWN REFUSAL. The park is a compensation, not a second
          # decision — the return value is the PUSH refusal, never the release's or the
          # escalation's.
          assert {:error, :runner_not_connected} =
                   place(ctx, dispatch_payload(story), actor_label: "api:dispatch_placement")
        end)

      assert log =~ "the story is ESCALATED"
      refute log =~ "COULD NOT ESCALATE"

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "release of that claim ALSO failed"
      assert row.escalation_reason =~ "resolve_escalation"

      # THE CLAIM IS STILL STANDING, which is the state this whole branch exists for and the
      # thing the trigger is scoped to produce: the Multi aborted at its `:stage` step, so the
      # `:story` write rolled back with it and the story is `assigned` at an in-flight stage
      # with a session that will never run. `implementer_dispatch_id` is gone because
      # `undo_claim/5`'s clear step runs on its own transaction and succeeded.
      held = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert held.agent_status == :assigned
      assert held.assigned_agent_id == runner.agent_id
      assert held.claim_epoch == row.claim_epoch
      assert held.claim_epoch > story.claim_epoch

      # AND THE PARK NAMES WHAT IT WAS FOR. Both callers of `place/4` always pass an
      # `:actor_label`, so `@escalation_actor` is never reached in production and a DEFAULT
      # could not distinguish this park from the one `StoryPayload.build/3` writes for a story
      # loopctl cannot describe — `attach_story/6` forwards the SAME key into it. The suffix is
      # what makes the two tellable apart in the escalated queue, so it is asserted against the
      # caller's label rather than against a literal the code could drift from.
      assert [event] = unboxed(fn -> escalation_events(runner.tenant_id, story.id) end)
      assert event.actor_label == "api:dispatch_placement/unreleased-claim"
      refute event.actor_label == "api:dispatch_placement"
    end

    test "a claim the undo could not give back is PARKED for a human", ctx do
      %{runner: runner, story: story} = ctx

      # A REAL placement, so the story is genuinely `assigned` at stage `claimed` with a live
      # session dispatch recorded on it — the state a failed release leaves behind, built the
      # only way it can actually arise.
      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :claimed

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   unboxed(fn ->
                     Placement.escalate_unreleased_claim(
                       runner.tenant_id,
                       claimed,
                       session,
                       :runner_not_connected,
                       :not_found,
                       actor_label: "test"
                     )
                   end)
        end)

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :escalated
      assert log =~ "the story is ESCALATED"

      # THE REASON IS OPERATOR-FACING AND NAMES THE REMEDY, which is the whole of what makes
      # this better than the `Logger.error` it replaces: an operator reading the escalated
      # queue must be able to act without going and finding the log line. Both remedies,
      # because they are reached from different places and leave the story in different
      # states.
      assert row.escalation_reason =~ "resolve_escalation"
      assert row.escalation_reason =~ "force_unclaim_story"
      assert row.escalation_reason =~ "release of that claim ALSO failed"

      # AND THE SECOND REMEDY SAYS WHAT IT DOES NOT DO. This text is read off an ESCALATED
      # row, and force-unclaim does not clear an escalation — the next test proves that from
      # the behaviour rather than from this string. The wording it replaces ("leaves the story
      # at pending: contract it before placing it again") sent an operator to a
      # `{:error, :wrong_stage}` from `claimable/2` with nothing saying why.
      assert row.escalation_reason =~ "does NOT clear this escalation"
      refute row.escalation_reason =~ "contract it before placing it again"

      # And it is LOOPCTL'S OWN WORDS carrying loopctl's own error terms — there is no path
      # here by which session-authored text reaches an append-only chain entry.
      assert row.escalation_reason =~ "placement_error=:runner_not_connected"
      assert row.escalation_reason =~ "release_error=:not_found"

      # THE CLAIM IS STILL STANDING. This parks the story; it does not pretend to have freed
      # it — freeing it is what just failed. `resolve_escalation` to `queued` is the one call
      # that does both, which is why the reason names it first.
      still_held = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert still_held.assigned_agent_id == claimed.assigned_agent_id
      assert still_held.claim_epoch == claimed.claim_epoch
      assert still_held.implementer_dispatch_id == session.id
    end

    # WHAT THE ESCALATION REASON'S SECOND REMEDY ACTUALLY DOES, asserted rather than described.
    # `Stages.follow_release/5` requeues only a row whose stage is in
    # `StageMachine.in_flight_stages/0` and REBINDS everything else; `escalated` is not in that
    # list, so a force-unclaim frees the claim and the stage row survives it untouched. The
    # reason text said the opposite until #865 round 1 — a prose claim about a mechanism, in
    # the one column an unattended loop expects an operator to act from, that nothing checked.
    test "force-unclaiming a PARKED story frees the claim and leaves the stage escalated", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 unboxed(fn ->
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     :runner_not_connected,
                     :not_found,
                     []
                   )
                 end)
      end)

      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :escalated

      assert {:ok, freed} =
               unboxed(fn ->
                 Progress.force_unclaim_story(runner.tenant_id, story.id, actor_label: "test")
               end)

      # THE CLAIM IS GONE — that half of the remedy is real and the reason still names it.
      assert freed.agent_status == :pending
      assert is_nil(freed.assigned_agent_id)

      # AND THE ESCALATION IS NOT. The row took the new epoch (a rebind) and kept its stage.
      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :escalated
      assert row.claim_epoch == freed.claim_epoch

      # SO CONTRACTING IT IS NOT ENOUGH, which is exactly what the old wording promised it was.
      assert {:ok, _contracted} =
               unboxed(fn ->
                 Progress.contract_story(runner.tenant_id, story.id, %{},
                   actor_label: "test",
                   skip_contract_check: true
                 )
               end)

      assert {:error, :wrong_stage} =
               unboxed(fn -> Placement.claimable(runner.tenant_id, story.id) end)
    end

    test "the park is attributed to the PLACEMENT CALLER, not to the session that never ran",
         ctx do
      %{runner: runner, story: story} = ctx
      %{dispatch: parent, api_key: parent_key} = unboxed(fn -> orchestrator(runner.tenant_id) end)

      # A LINEAGED caller, deliberately: with the default operator key the session dispatch is
      # a ROOT, so `Enum.drop(lineage_path, -1)` is `[]` and the correct value would equal the
      # value a defaulted-lineage defect writes. A parent is what makes the two differ.
      assert {:ok, _placed} = place(ctx, dispatch_payload(story), api_key: parent_key)
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 unboxed(fn ->
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     :runner_not_connected,
                     :not_found,
                     []
                   )
                 end)
      end)

      # Entering `escalated` is CHAINED, so this writes an immutable entry naming an actor.
      # The session was minted and never ran, so recording ITS lineage would say a session
      # asked for a human when no session existed; the principal that acted is the one that
      # asked for the placement, which is what `release_claim/5` and `revoke_session_dispatch/3`
      # already record for their own compensations.
      assert [entry] = unboxed(fn -> escalated_entries(runner.tenant_id, story.id) end)
      assert entry.actor_lineage == Enum.drop(session.lineage_path, -1)
      assert entry.actor_lineage == parent.lineage_path
      refute entry.actor_lineage == session.lineage_path
    end

    test "a stage with no escalation edge is reported stranded, and nothing is written", ctx do
      %{runner: runner, story: story} = ctx

      # `enter_claimed_and_push/6` also reaches its `else` when the `queued -> claimed` advance
      # itself was refused — a story that is CLAIMED while its row is still at `queued`, which
      # `:session_escalated` cannot leave. Staged here by claiming without advancing the row.
      claimed = unboxed(fn -> claim_without_advancing(runner, story) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   unboxed(fn ->
                     Placement.escalate_unreleased_claim(
                       runner.tenant_id,
                       claimed,
                       session,
                       :busy,
                       :not_found,
                       []
                     )
                   end)
        end)

      # NAMED, not reported as a bare `:invalid_transition` an operator has to decode — and
      # loud, because this is the story that is neither placeable nor parked.
      assert log =~ "COULD NOT ESCALATE"
      assert log =~ "no_escalation_edge"
      assert log =~ "force-unclaim"

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :queued
      assert is_nil(row.escalation_reason)
    end

    test "a claim epoch that has moved refuses the park rather than taking somebody else's",
         ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      # The fence, and the reason the epoch is the CLAIM's and is never re-read: a compensation
      # holding a spent epoch must not park a story whose claim has since gone back and been
      # re-taken. Staged by handing it an epoch the row will not match.
      stale = %{claimed | claim_epoch: claimed.claim_epoch - 1}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   unboxed(fn ->
                     Placement.escalate_unreleased_claim(
                       runner.tenant_id,
                       stale,
                       session,
                       :runner_not_connected,
                       :not_found,
                       []
                     )
                   end)
        end)

      assert log =~ "COULD NOT ESCALATE"
      assert log =~ "stale_claim_epoch"

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :claimed
      assert is_nil(row.escalation_reason)
    end

    test "a pathological error term cannot lose the escalation", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      # `story_stages_text_bounds` is a CHECK, and `Stages.advance/4` refuses an over-long
      # reason with `:invalid_reason` BEFORE the transition — so a fat error term would turn
      # "the release failed" into "the release failed AND the story could not be parked",
      # which is the one outcome nothing downstream picks up. `short/1` is what stops it, and
      # this is where that bound is reachable: an exception carrying a 20 KB message is the
      # realistic shape (a `DBConnection` error under pool pressure is the failure the
      # incident actually was), and unbounded it is five times the column's limit.
      huge = String.duplicate("x", 20_000)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 unboxed(fn ->
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     :runner_not_connected,
                     %RuntimeError{message: huge},
                     []
                   )
                 end)
      end)

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :escalated
      assert String.length(row.escalation_reason) <= StageMachine.max_reason_length()

      # AND THE REMEDY IS INTACT. NOTHING WAS TRUNCATED HERE — this comment used to say the
      # remedy "survived the truncation", and no truncation happens: the whole-text clamp was
      # deleted and `short/1` bounded the TERM, so the reason was never near the cap to begin
      # with. What the two lines below actually hold is that bounding the term did not cost the
      # instruction. The ordering argument (remedy first, diagnostics last) is about what a
      # FUTURE overrun would lose, and is stated where it belongs, above
      # `unreleased_claim_reason/2`.
      assert row.escalation_reason =~ "resolve_escalation"
      assert row.escalation_reason =~ "force_unclaim_story"
    end

    test "a raise inside the park does not replace the refusal the caller is owed", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      # `Stages.get/2` and the chain append run on pools with no `lock_timeout` of their own,
      # so a DBConnection error here is a RAISE rather than an `{:error, _}` — the same shape
      # `release_claim/5` rescues for the same reason. Unrescued, it would replace the PUSH
      # refusal `place/4` owes its caller with a second, unrelated exception, and the caller
      # would never learn why its dispatch was refused. Staged with an unusable story id,
      # which is the cheapest thing that raises inside the first step.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   unboxed(fn ->
                     Placement.escalate_unreleased_claim(
                       runner.tenant_id,
                       %{claimed | id: "not-a-uuid"},
                       session,
                       :runner_not_connected,
                       :not_found,
                       []
                     )
                   end)
        end)

      assert log =~ "COULD NOT ESCALATE"

      # And it changed nothing on the way past.
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :claimed
    end

    test "a story already parked is left exactly as it is, and is not parked twice", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      session = unboxed(fn -> session_dispatch(runner.tenant_id, story.id) end)

      park = fn ->
        unboxed(fn ->
          Placement.escalate_unreleased_claim(
            runner.tenant_id,
            claimed,
            session,
            :runner_not_connected,
            :not_found,
            []
          )
        end)
      end

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = park.() end)
      first = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)

      # A REPEAT — a retried placement, or a node that died between the advance and the
      # return. `escalated` has no `:session_escalated` edge leaving it, so nothing is
      # attempted at all and `StoryPayload.settle_if_parked/3` reads the row as the outcome
      # this call wanted: no second `attempts` count, no second chain entry.
      repeat_log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = park.() end)
      second = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)

      # AND IT IS REPORTED AS THE OUTCOME IT IS, not as a failure to reach it. That is
      # `StoryPayload.settle_if_parked/3` doing its job: without the re-read this would take
      # the loud "COULD NOT ESCALATE" branch on a story that is parked, which is exactly the
      # noise that trains an operator to skip the line that matters.
      assert repeat_log =~ "the story is ESCALATED"
      refute repeat_log =~ "COULD NOT ESCALATE"

      assert second.stage == :escalated
      assert second.lock_version == first.lock_version
      assert second.attempts == first.attempts
      assert length(unboxed(fn -> escalated_entries(runner.tenant_id, story.id) end)) == 1
    end

    test "a payload with no usable dispatch_id is refused before anything is claimed", ctx do
      %{runner: runner, story: story} = ctx
      payload = Map.put(dispatch_payload(story), "dispatch_id", "not-a-uuid")

      assert {:error, {:invalid, ["dispatch_id: must be a UUID"]}} = place(ctx, payload)

      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
    end
  end

  describe "delete_audit_chain_rows!/1 — what makes the committed-runner sweep possible" do
    test "deletes immutable entries, and leaves the connection's triggers ON", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout
      assert unboxed(fn -> claimed_entry(runner.tenant_id, story.id) end)

      raw_id = Ecto.UUID.dump!(runner.tenant_id)

      # ONE `unboxed/1` block, so both assertions read the SAME checked-out connection. Reading
      # the setting from a second block proves nothing: the pool would hand back a different
      # connection and report `origin` whether or not the first one leaked, which is precisely
      # what makes this hazard nondeterministic in production use — `bin/mutate.sh` came back
      # exit 1 on the two-block version.
      unboxed(fn ->
        delete_audit_chain_rows!([raw_id])

        # 1. It deletes. Without the suppression `audit_chain_prevent_delete_trigger` raises
        #    and every committed test tenant becomes permanently undeletable.
        assert chain_entry_count(runner.tenant_id) == 0

        # 2. It does not LEAK. `SET LOCAL` reverts with the transaction; a bare `SET` leaves
        #    THIS connection in `replica` when it goes back to the pool, so the next test runs
        #    with user triggers and FK enforcement off — the audit chain's own protection
        #    included — and nothing says so.
        assert replication_role() == "origin"
      end)
    end
  end

  describe "the minted credential does not reach the session" do
    test "the dispatch payload carries exactly these fields, and none of them is a credential" do
      # The premise of the moduledoc's "the credential ... does NOT reach the session" section.
      #
      # THE EXACT SET, not a substring match on "key": a field named `credential`, `token`,
      # `secret`, `auth` or `raw` would have passed a name filter, and the property being
      # asserted is that the payload carries NO way to hand a session a credential — which no
      # vocabulary list can decide, because the next such field will be named something nobody
      # listed. Pinning the set makes whoever adds ANY field come and look at this test, which
      # is the only place the question gets asked.
      #
      # AT EVERY DEPTH THE PAYLOAD HAS. `cast_dispatch/1` drops undeclared keys at any depth,
      # so a credential can only arrive in a DECLARED field — and a field declared under the
      # nested `story:` object leaves the top-level key set unchanged. Pinning one level and
      # claiming the property for the whole payload is the same defect as the substring match,
      # one level of nesting along. `RunnerStory`'s own properties are scalars and arrays of
      # scalars, so these two sets are the whole shape; a THIRD level would need its own line
      # here, which is the point of asserting rather than describing.
      assert RunnerContract.RunnerDispatch.schema().properties |> Map.keys() |> Enum.sort() == [
               :base_branch,
               :branch,
               :claim_epoch,
               :dispatch_id,
               :kind,
               :max_turns,
               :repo,
               :story,
               :story_id,
               :token_budget,
               :triage,
               :wall_clock_seconds
             ]

      # `triage` (contract 1.7.0) is the second nested object and is pinned for the same
      # reason as `story`. Answering the question this test exists to ask: none of its fields
      # can carry a credential. Four are loopctl's own scalars, `escalation_reasons` is an
      # array of loopctl's own detector codes, and `untrusted` is reporter text that has been
      # through `Untrusted.render/2` — text a session must treat as data, which is the
      # opposite of a credential and is fenced precisely so it cannot act as one.
      assert RunnerContract.RunnerTriage.schema().properties |> Map.keys() |> Enum.sort() == [
               :escalation_reasons,
               :html_url,
               :issue_number,
               :record_id,
               :truncated,
               :untrusted
             ]

      assert RunnerContract.RunnerStory.schema().properties |> Map.keys() |> Enum.sort() == [
               :acceptance_criteria,
               :description,
               :domain_reference,
               :id,
               :test_cases,
               :title,
               :touches
             ]
    end
  end

  # --- helpers ------------------------------------------------------------------------------

  # `ctx` carries the operator key, so the default caller is the one principal allowed to root
  # a tree. Pass `api_key:` to place as somebody else.
  defp place(ctx, payload, opts \\ []) do
    %{runner: runner, operator: operator} = ctx
    opts = Keyword.merge([api_key: operator], opts)
    unboxed(fn -> Placement.place(runner.tenant_id, runner.id, payload, opts) end)
  end

  # BOTH repos on real connections. A placement writes through each of them and the sandbox
  # gives them separate, mutually invisible transactions — see the moduledoc.
  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  # A story contracted and standing at `queued`, which is what a placement takes.
  defp contract_and_queue(tenant_id, story) do
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

  # An orchestrator dispatch and the key it minted — a LINEAGED caller, so the placement it
  # makes parents inside its own subtree rather than rooting a new tree.
  defp orchestrator(tenant_id) do
    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant_id, %{role: :orchestrator}, actor_lineage: [])

    %{dispatch: dispatch, api_key: AdminRepo.get!(ApiKey, dispatch.api_key_id)}
  end

  # An AGENT-role dispatch and the key it minted: lineaged, so it clears the root gate, and
  # below `:orchestrator`, so it must not clear the mint gate.
  defp lineaged_agent(tenant_id) do
    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: nil}, actor_lineage: [])

    %{dispatch: dispatch, api_key: AdminRepo.get!(ApiKey, dispatch.api_key_id)}
  end

  defp halt_custody(tenant_id) do
    Tenant
    |> AdminRepo.get!(tenant_id)
    |> Ecto.Changeset.change(custody_halted_at: DateTime.utc_now())
    |> AdminRepo.update!()
  end

  defp set_trust_tier(tenant_id, tier) do
    Tenant
    |> AdminRepo.get!(tenant_id)
    |> Ecto.Changeset.change(trust_tier: tier)
    |> AdminRepo.update!()
  end

  defp chain_entry_count(tenant_id) do
    AdminRepo.aggregate(
      from(e in AuditChain.Entry, where: e.tenant_id == ^tenant_id),
      :count,
      :id
    )
  end

  defp replication_role do
    %{rows: [[role]]} = AdminRepo.query!("SHOW session_replication_role")
    role
  end

  defp session_dispatch(tenant_id, story_id) do
    AdminRepo.one!(
      from d in Dispatch, where: d.tenant_id == ^tenant_id and d.story_id == ^story_id
    )
  end

  defp tenant_dispatch_count(tenant_id) do
    AdminRepo.aggregate(from(d in Dispatch, where: d.tenant_id == ^tenant_id), :count, :id)
  end

  # NO `story` KEY: loopctl builds the object itself now (`attach_story/6`), and `place/4`
  # REFUSES a caller-supplied one — a caller able to hand a runner prose is able to run
  # anything on that machine. What the runner receives is asserted in "the dispatch carries
  # the story object loopctl built" rather than echoed from here.
  defp dispatch_payload(story), do: build(:runner_dispatch, %{"story_id" => story.id})

  # The criteria as `ImplementerInput.story_object/2` renders them — the one derivation, so
  # this asserts the object came from the story rather than re-implementing the builder here.
  defp expected_criteria(story) do
    {:ok, object} = ImplementerInput.story_object(story)
    object["acceptance_criteria"]
  end

  defp give_criteria!(tenant_id, story_id) do
    {1, _} =
      AdminRepo.update_all(
        from(s in Story,
          where: s.id == ^story_id and s.tenant_id == ^tenant_id
        ),
        set: [
          acceptance_criteria: [
            %{"id" => "AC-1", "description" => "The monthly total equals the sum of its visits"}
          ]
        ]
      )
  end

  # A description past `RunnerStory.max_bytes/0` under the contract's byte rule (6 bytes per
  # character, 12 per string). Written straight to the row: no changeset needs to allow this,
  # and the point is a story that EXISTS and cannot be described within the contract.
  defp oversize!(tenant_id, story_id) do
    {1, _} =
      AdminRepo.update_all(
        from(s in Story,
          where: s.id == ^story_id and s.tenant_id == ^tenant_id
        ),
        set: [description: String.duplicate("a", 20_000)]
      )
  end

  # The story's project bound to a repository, which is where the fill reads `repo` and
  # `base_branch` from.
  defp bind_repo(tenant_id, story, repo) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Loopctl.Intake.Source{
      tenant_id: tenant_id,
      project_id: story.project_id,
      repo_full_name: repo,
      base_branch: "master",
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })
  end

  defp reload(tenant_id, story_id) do
    {:ok, story} = Stories.get_story(tenant_id, story_id)
    story
  end

  defp claimed_entry(tenant_id, story_id) do
    AdminRepo.one!(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^story_id,
        where: e.action == "story_stage_claimed"
    )
  end

  defp escalated_entries(tenant_id, story_id) do
    AdminRepo.all(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^story_id,
        where: e.action == "story_stage_escalated"
    )
  end

  # The STAGE EVENT rather than the chain entry, because `actor_label` is a column on
  # `story_stage_events` and is not on a chain entry at all.
  defp escalation_events(tenant_id, story_id) do
    AdminRepo.all(
      from e in StageEvent,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
        where: e.to_stage == "escalated",
        order_by: e.inserted_at
    )
  end

  # MAKES THE RELEASE FAIL THE ONE WAY PRODUCTION DID, which nothing in Elixir can stage.
  # `Progress.force_unclaim_story/3` writes the release and the stage row in ONE `AdminRepo`
  # transaction and rescues its only post-commit step, so every failure mode reachable from a
  # mock breaks the CLAIM first — and a story with no claim needs no compensation. What the
  # incident actually was is the `:stage` step failing with the `:story` write rolling back
  # WITH it: claim intact, `release_claim/5` reporting `{:error, _}` out of its rescue. A
  # `BEFORE UPDATE` trigger produces exactly that, and costs nothing here because this file is
  # already `async: false` on committed, unboxed rows (see the moduledoc) — a sandboxed file
  # could not do this without the DDL being rolled back under it.
  #
  # SCOPED TO THE RELEASE'S OWN WRITE, and the scoping is the whole trick, because FOUR
  # statements update this one row during a single refused `place/4`:
  #
  #   * `Stages.follow_claim/4`, inside the claim, REBINDS:   `queued  -> queued`
  #   * the `{:queued, :claimed}` advance:                    `queued  -> claimed`
  #   * the release's `Stages.follow_release/5` requeue:      `claimed -> queued`   <- this one
  #   * the park that follows it:                             `claimed -> escalated`
  #
  # Only the third pair is `OLD.stage = 'claimed' AND NEW.stage = 'queued'`, so that predicate
  # names the release alone. On `NEW.stage = 'queued'` by itself the trigger would fire on the
  # claim's own rebind and break the CLAIM instead — the state that needs no compensation, and
  # a test that would then pass while proving nothing.
  #
  # The story id is INTERPOLATED because a `CREATE TRIGGER ... WHEN` clause takes no bind
  # parameters. It is a uuid this test's own fixture generated, not caller input.
  defp fail_the_release!(story_id) do
    name = "placement_release_fails_#{System.unique_integer([:positive])}"

    unboxed(fn ->
      {:ok, _} =
        AdminRepo.transaction(fn ->
          # `SET LOCAL`, never a bare `SET`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock, so
          # this fails fast instead of hanging the run, and the setting reverts with the
          # transaction rather than riding a pooled connection into the next test.
          AdminRepo.query!("SET LOCAL lock_timeout = '5s'")

          AdminRepo.query!(
            "CREATE FUNCTION #{name}() RETURNS trigger AS $fn$ BEGIN " <>
              "RAISE EXCEPTION 'placement test: the release cannot write this row'; " <>
              "END; $fn$ LANGUAGE plpgsql"
          )

          AdminRepo.query!(
            "CREATE TRIGGER #{name}_t BEFORE UPDATE ON story_stages FOR EACH ROW " <>
              "WHEN (NEW.story_id = '#{story_id}'::uuid " <>
              "AND OLD.stage = 'claimed' AND NEW.stage = 'queued') " <>
              "EXECUTE FUNCTION #{name}()"
          )
        end)
    end)

    # DROPPED EXPLICITLY, because nothing else will. The rows here are committed, so there is
    # no sandbox rollback to undo the DDL — a leaked trigger would fail every later release of
    # a story that happened to reuse this id, and the function would outlive the database's
    # tenants. `IF EXISTS` so a failure before the trigger was created still cleans up.
    on_exit(fn ->
      Sandbox.unboxed_run(AdminRepo, fn ->
        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name}_t ON story_stages")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)
    end)

    :ok
  end

  # A story CLAIMED while its stage row is still at `queued` — what
  # `enter_claimed_and_push/6` leaves behind when the `queued -> claimed` advance itself is
  # refused. Built the way the placement builds it (a session dispatch minted FOR the story,
  # recorded as `implementer_dispatch_id`) and then simply not advanced.
  defp claim_without_advancing(runner, story) do
    {:ok, %{dispatch: session}} =
      Dispatches.create_dispatch(
        runner.tenant_id,
        %{role: :agent, agent_id: runner.agent_id, story_id: story.id},
        actor_lineage: []
      )

    {:ok, claimed} =
      Progress.claim_story(runner.tenant_id, story.id,
        agent_id: runner.agent_id,
        dispatch_id: session.id,
        lineage: session.lineage_path,
        actor_label: "test"
      )

    claimed
  end

  defp revoked_entries(tenant_id, dispatch_id) do
    AdminRepo.all(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^dispatch_id,
        where: e.action == "dispatch_revoked"
    )
  end

  defp session_dispatch_count(tenant_id, story_id) do
    AdminRepo.aggregate(
      from(d in Dispatch, where: d.tenant_id == ^tenant_id and d.story_id == ^story_id),
      :count,
      :id
    )
  end

  # Unlinked first: `leave/1` shuts the channel down with `{:shutdown, :left}`, and
  # `subscribe_and_join/3` linked it to the test process, so the exit would take the test with
  # it before a single assertion ran.
  defp disconnect(channel, runner) do
    Process.unlink(channel.channel_pid)
    leave(channel)
    wait_until_disconnected(runner)
  end

  # Presence untracks when the channel process EXITS, which happens after `leave/1` returns, so
  # this polls rather than asserting once. It needs a real pause between attempts: a tight
  # recursion spent all fifty in well under a millisecond and flaked roughly one run in four.
  defp wait_until_disconnected(runner, attempts \\ 100) do
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

  defp connect_info(token) do
    %{
      x_headers: [{RunnerSocket.token_header(), token}],
      peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
    }
  end

  defp join_payload(machine) do
    %{
      "contract_version" => RunnerContract.version(),
      "machine" => machine,
      "cores" => 16,
      "memory_mb" => 28_000,
      "repos" => ["mkreyman/home_care_billing"],
      "max_sessions" => 2,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
