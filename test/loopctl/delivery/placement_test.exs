defmodule Loopctl.Delivery.PlacementTest do
  @moduledoc """
  Issue #803: the dispatch claims the story it is sent for.

  A placement spans BOTH repos — the claim is an `AdminRepo` transaction
  (`Loopctl.Progress.claim_story/3`) and the `queued -> claimed` transition is a `Loopctl.Repo`
  one, because `Loopctl.AuditChain.append_in_tenant_transaction/2` raises outside a `Repo`
  transaction and that transition is chained — and the runner socket's channel process records
  the push. AdminRepo runs on Repo's sandbox connection in test (`Loopctl.AdminRepo.Route`) and
  the channel process inherits the test's `$callers`, so all of them work on this test's one
  sandbox transaction and nothing here commits. The tests that inject a failure with DDL, and
  the test of the committed-row sweep itself, are `Loopctl.Delivery.PlacementFaultTest`.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query
  import Loopctl.Test.Placement

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.AuditChain
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.ImplementerInput
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.OwnLog
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  @reply_timeout 2_000

  setup do
    # HUMAN-ANCHORED explicitly: `place/4` applies the L0 tier gate itself.
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
    {_operator_raw, operator} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    {:ok, socket} =
      connect(RunnerSocket, %{}, connect_info: build(:runner_connect_info, %{token: raw}))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> runner.id,
        build(:runner_join_payload, %{"machine" => "minis"})
      )

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:ledger_story, %{tenant_id: runner.tenant_id})
    story = contract_and_queue(runner.tenant_id, story)

    %{runner: runner, channel: channel, story: story, operator: operator, runner_key: raw}
  end

  describe "place/4" do
    test "the dispatch carries the story object loopctl built from its own row", ctx do
      %{runner: runner, story: story} = ctx

      # Real acceptance criteria on the ROW, because they are what an implementer is judged
      # against and what the fixture story does not have: without them the object is a title
      # and an id, and this test would pass on a dispatch carrying no work either.
      give_criteria!(runner.tenant_id, story.id)
      story = reload(runner.tenant_id, story.id)

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
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
      source = bind_repo(runner.tenant_id, story, "mkreyman/home_care_billing")

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

    # US-45.4: the merge ROUTE is bound on the implement ledger row at placement — the mode from
    # the same source read that filled `repo` and `base_branch`, and the base branch the
    # dispatch was sent with — and neither is put on the wire.
    test "the ledger row binds the source's mode and the base branch sent, off the wire", ctx do
      %{runner: runner, story: story} = ctx
      bind_repo(runner.tenant_id, story, "mkreyman/thread_repo", :thread)

      minimal = %{
        "dispatch_id" => Ecto.UUID.generate(),
        "story_id" => story.id,
        "kind" => "implement",
        "wall_clock_seconds" => 3_600,
        "max_turns" => 50
      }

      assert {:ok, placed} = place(ctx, minimal)
      assert_push "dispatch", pushed, @reply_timeout
      refute Map.has_key?(pushed, :mode)
      refute Map.has_key?(pushed, :placed_mode)

      row = DispatchLedger.get_record(runner.tenant_id, placed.dispatch_id)
      assert row.mode == "thread"
      assert row.base_branch == "master"
    end

    test "a caller that named repo and base_branch still binds the source's mode", ctx do
      %{runner: runner, story: story} = ctx
      bind_repo(runner.tenant_id, story, "mkreyman/thread_repo", :thread)

      # The caller's own refs mean nothing resolved the source; a project-filtered read
      # answers the mode. A caller-sent "mode" is not the route: only loopctl binds it.
      payload =
        :placement_dispatch
        |> build(%{"story_id" => story.id})
        |> Map.merge(%{"base_branch" => "main", "mode" => "pr", "placed_mode" => "pr"})

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      row = DispatchLedger.get_record(runner.tenant_id, placed.dispatch_id)
      assert row.mode == "thread"
      assert row.base_branch == "main"
    end

    test "a caller-named dispatch for a project with no source records no mode", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      row = DispatchLedger.get_record(runner.tenant_id, placed.dispatch_id)
      assert row.mode == nil
    end

    test "a budget nobody configured is named BEFORE anything is minted", ctx do
      %{runner: runner, story: story} = ctx
      bind_repo(runner.tenant_id, story, "mkreyman/cron_books")

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

      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
    end

    test "a CALLER-supplied story object is refused, and nothing is claimed", ctx do
      %{runner: runner, story: story} = ctx

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "story",
          build(:runner_story, %{"id" => story.id})
        )

      # The contract's no-prompt rule, holding one level along: a caller able to hand a runner
      # an arbitrary story object is a caller able to hand it prose to execute, and a dispatch
      # runs as the machine's user. Refused in `place/4` and not only at the HTTP edge,
      # because a worker, an MCP tool and the unattended driver never pass through that edge.
      assert {:error, :story_not_accepted} = place(ctx, payload)
      refute_push "dispatch", _pushed

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :queued
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
    end

    test "a story too large for the contract is ESCALATED, and the claim goes back", ctx do
      %{runner: runner, story: story} = ctx

      # Oversize by the contract's own byte rule, which charges 6 bytes per character. loopctl
      # REFUSES such a story rather than truncating it — a dropped acceptance criterion is a
      # story built to the wrong spec and an implementer cannot tell three criteria from four
      # with the fourth cut.
      oversize!(runner.tenant_id, story.id)

      assert {:error, {:story_not_dispatchable, [_ | _]}} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      refute_push "dispatch", _pushed

      # ESCALATED, not requeued, and both halves matter. The escalation is where the builder
      # put the story — a human has it — and `undo_claim/5` must not fight that:
      # `Stages.follow_release/5` requeues only an IN-FLIGHT row and rebinds anything else, so
      # the row keeps `escalated` and takes the released epoch rather than going back to
      # `queued` for the next pass to fail on identically.
      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :escalated

      # And the claim is released: no session will ever run under it.
      released = reload(runner.tenant_id, story.id)
      assert released.assigned_agent_id == nil
      assert released.claim_epoch > story.claim_epoch
      assert row.claim_epoch == released.claim_epoch
    end

    test "claims the story, enters `claimed` and pushes the dispatch", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.dispatch_id == payload["dispatch_id"]
      assert pushed.claim_epoch == placed.claim_epoch

      claimed = reload(runner.tenant_id, story.id)
      assert claimed.agent_status == :assigned
      assert claimed.assigned_agent_id == runner.agent_id
      assert claimed.implementer_dispatch_id == placed.implementer_dispatch_id
      assert claimed.claim_epoch == placed.claim_epoch
      assert claimed.claim_epoch > story.claim_epoch

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :claimed
      assert row.runner_id == runner.id
      assert row.claim_epoch == placed.claim_epoch
    end

    test "the claim's chain entry is attributed to the dispatch it minted", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      session = AdminRepo.get!(Dispatch, placed.implementer_dispatch_id)
      entry = claimed_entry(runner.tenant_id, story.id)

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
      %{dispatch: parent, api_key: parent_key} = orchestrator(runner.tenant_id)

      assert {:ok, placed} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}),
                 api_key: parent_key
               )

      assert_push "dispatch", _pushed, @reply_timeout

      session = AdminRepo.get!(Dispatch, placed.implementer_dispatch_id)
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
      {:ok, runner_api_key} = Loopctl.Auth.verify_api_key(raw)

      assert {:error, :root_dispatch_forbidden} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}),
                 api_key: runner_api_key
               )

      refute_push "dispatch", _pushed, 200

      untouched = reload(runner.tenant_id, story.id)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
    end

    test "a key from another tenant is not authorized, whatever its role", ctx do
      %{story: story} = ctx
      other = fixture(:tenant, %{trust_tier: :human_anchored})
      {_raw, intruder} = fixture(:api_key, %{tenant_id: other.id, role: :user})

      assert {:error, :not_authorized} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}),
                 api_key: intruder
               )

      refute_push "dispatch", _pushed, 200
    end

    test "an agent_rooted tenant is refused the whole path, and claims nothing", ctx do
      # The L0 gate, applied in the context because no plug can reach here. Both halves of
      # what this path does — minting a custody dispatch and driving a chained custody
      # transition — are human-anchored on the HTTP surface.
      %{runner: runner, story: story} = ctx
      set_trust_tier(runner.tenant_id, :agent_rooted)

      assert {:error, :custody_tier_required} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      refute_push "dispatch", _pushed, 200

      untouched = reload(runner.tenant_id, story.id)
      assert untouched.agent_status == :contracted
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
    end

    test "a halted tenant is refused the whole path, and nothing is minted or claimed", ctx do
      # L6. `CheckCustodyHalt` is a pipeline plug and there is no `conn` here;
      # `Runners.dispatch/3`'s own halt check runs at the PUSH, after the mint and after both
      # commits. And the usual backstop does not apply — `ReclaimExpiredClaimsWorker` skips
      # halted tenants — so a claim left standing on one is never reclaimed.
      %{runner: runner, story: story} = ctx
      before = tenant_dispatch_count(runner.tenant_id)
      # The runner's enrolment is already on the chain; the refused placement adds nothing.
      chained = chain_entry_count(runner.tenant_id)
      halt_custody(runner.tenant_id)

      assert {:error, :tenant_halted} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      refute_push "dispatch", _pushed, 200

      assert tenant_dispatch_count(runner.tenant_id) == before
      untouched = reload(runner.tenant_id, story.id)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
      assert chain_entry_count(runner.tenant_id) == chained
    end

    test "a lineaged caller below :orchestrator may not mint at all", ctx do
      # `DispatchController` mounts `RequireRole, role: :orchestrator` on `:create` and
      # `create_dispatch/3` has no role gate of its own, so without this an AGENT-role key that
      # some dispatch minted could mint a child custody dispatch and a live ephemeral key
      # through a path the HTTP surface 403s.
      %{runner: runner, story: story} = ctx
      %{api_key: agent_key} = lineaged_agent(runner.tenant_id)
      before = tenant_dispatch_count(runner.tenant_id)

      assert {:error, :insufficient_role} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}),
                 api_key: agent_key
               )

      refute_push "dispatch", _pushed, 200
      assert tenant_dispatch_count(runner.tenant_id) == before
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
    end

    # #884: `pending` at `queued` is where a triage-accepted story, a release whose re-contract
    # did not land and an escalation resolved to `queued` all wait. The placement contracts it
    # inside its claim; nothing unattended did before.
    test "a PENDING story at queued is contracted and claimed by the placement", ctx do
      %{runner: runner, story: story} = ctx

      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
          set: [agent_status: :pending]
        )

      assert :ok = Placement.claimable(runner.tenant_id, story.id)
      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      assert reload(runner.tenant_id, story.id).agent_status == :assigned

      # Attributed to the key that placed it, not to nobody (#884 review round 3).
      contracted_by =
        AdminRepo.one(
          from a in Loopctl.Audit.AuditLog,
            where: a.entity_id == ^story.id and a.action == "status_changed",
            where: fragment("?->>'agent_status' = 'contracted'", a.new_state),
            where: a.actor_id == ^ctx.operator.id,
            select: {a.actor_id, a.new_state}
        )

      assert {actor_id, new_state} = contracted_by
      assert actor_id == ctx.operator.id
      # And names the runner's agent it was contracted for (#887 review round 1).
      assert new_state["agent_id"] == runner.agent_id
    end

    test "a story that is neither pending nor contracted is refused before anything is minted",
         ctx do
      %{runner: runner, story: story} = ctx
      before = tenant_dispatch_count(runner.tenant_id)

      # A stale `queued` row behind a story that is already claimed.
      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
          set: [agent_status: :assigned]
        )

      assert {:error, :invalid_transition} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      assert tenant_dispatch_count(runner.tenant_id) == before
    end

    # #884 review round 3, finding 6. A triage-accepted story with unmet dependencies reaches
    # the driver `pending`; refused before the mint, not by the claim after it, every pass.
    test "unmet dependencies are refused before anything is minted or contracted", ctx do
      %{runner: runner, story: story} = ctx
      before = tenant_dispatch_count(runner.tenant_id)
      blocker = fixture(:ledger_story, %{tenant_id: runner.tenant_id})

      fixture(:story_dependency, %{
        tenant_id: runner.tenant_id,
        story_id: story.id,
        depends_on_story_id: blocker.id
      })

      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
          set: [agent_status: :pending]
        )

      assert {:error, :dependencies_not_met} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      assert tenant_dispatch_count(runner.tenant_id) == before
      assert reload(runner.tenant_id, story.id).agent_status == :pending
    end

    test "a story that is not ready is refused BEFORE anything is minted", ctx do
      %{runner: runner, story: story} = ctx
      before = tenant_dispatch_count(runner.tenant_id)

      # An operator's force-unclaim escalates the row (US-44.4): not at `queued`, not ready.
      Progress.force_unclaim_story(runner.tenant_id, story.id, [])

      assert {:error, :wrong_stage} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      # The point of the pre-check: a loop over an unready story writes no `dispatches` row,
      # no ephemeral key and no immutable chain entry, and takes the tenant's chain advisory
      # lock zero times.
      assert tenant_dispatch_count(runner.tenant_id) == before
      refute_push "dispatch", _pushed, 200
    end

    test "a stage row that is not at `queued` is refused before anything is minted", ctx do
      %{runner: runner} = ctx
      before = tenant_dispatch_count(runner.tenant_id)

      # A second story, CONTRACTED but left at `detected` — the story half of the readiness
      # check passes and the stage half does not, so this pins the stage half on its own.
      early = fixture(:ledger_story, %{tenant_id: runner.tenant_id})

      {:ok, early} =
        Progress.contract_story(runner.tenant_id, early.id, %{},
          actor_label: "test",
          skip_contract_check: true
        )

      {:ok, _row} = Stages.open(runner.tenant_id, early.id, actor_label: "test")

      assert Stages.get(runner.tenant_id, early.id).stage == :detected

      assert {:error, :wrong_stage} =
               place(ctx, build(:placement_dispatch, %{"story_id" => early.id}))

      assert tenant_dispatch_count(runner.tenant_id) == before
    end

    test "a dispatch_id is spent by the claim it was placed under", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _first} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      # The claim ends — an operator force-unclaims — so the ledger row's epoch is now a claim
      # that does not exist. Re-placing the SAME dispatch_id can never work again, which is the
      # fence doing its job and the reason `place/4`'s doc says a re-place needs a new id.
      Progress.force_unclaim_story(runner.tenant_id, story.id, [])

      assert {:error, :stale_claim_epoch} = place(ctx, payload)
    end

    test "a RESUME rebuilds the story object, and refuses rather than re-sending without one",
         ctx do
      %{runner: runner, story: story, channel: channel} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

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
      oversize!(runner.tenant_id, story.id)

      assert {:error, {:story_no_longer_dispatchable, [_ | _]}} = place(ctx, payload)

      # AND NOTHING WAS WRITTEN. A re-send does not own the claim it would be parking — the
      # story may be live under a session right now — and the ledger's own fences
      # (`dispatch_already_replied`, `stale_claim_epoch`) are not reached until the PUSH, so
      # escalating here would have written over a story nobody asked about, for a duplicate
      # retry of a dispatch that was already answered. Round 2 of this PR's review caught it.
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed
      still = reload(runner.tenant_id, story.id)
      assert still.agent_status == :assigned
      assert still.assigned_agent_id == runner.agent_id
    end

    test "an upper-case story_id is placed, and the object matches the id on the wire", ctx do
      %{runner: runner, story: story} = ctx
      shouty = String.upcase(story.id)
      payload = Map.put(build(:placement_dispatch, %{"story_id" => story.id}), "story_id", shouty)

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
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed
    end

    test "a re-sent dispatch_id claims nothing a second time, and releases nothing", ctx do
      %{runner: runner, story: story, channel: channel} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, first} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      # The runner goes away between the two placements, so the RETRY refuses at the push.
      # That is the interesting shape: the retry resumed from the ledger, so it must neither
      # claim again NOR release the claim the first placement made — a session may be running
      # under it. (That a re-send reaches the socket again is `Runners.dispatch/3`'s own
      # behaviour and is covered in `LoopctlWeb.RunnerChannelDispatchTest`.)
      disconnect(channel, runner)

      assert {:error, :runner_not_connected} = place(ctx, payload)

      after_retry = reload(runner.tenant_id, story.id)
      assert after_retry.claim_epoch == first.claim_epoch
      assert after_retry.agent_status == :assigned
      assert after_retry.implementer_dispatch_id == first.implementer_dispatch_id
      assert session_dispatch_count(runner.tenant_id, story.id) == 1
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed

      record =
        DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"])

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
        OwnLog.capture_naming(story.id, fn ->
          assert {:error, :runner_not_connected} =
                   place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
        end)

      refute log =~ "placement undo did not fully undo"

      # TC-44.4.1 (AC-44.4.1, AC-44.4.2): the runner refused before any work, so the undo's
      # release spends nothing and RE-CONTRACTS the story — back in front of the driver. It
      # used to leave `queued` + `:pending`, which no placement ever takes (#877).
      released = reload(runner.tenant_id, story.id)
      assert released.agent_status == :contracted
      assert is_nil(released.assigned_agent_id)

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :queued
      assert is_nil(row.runner_id)
      assert row.claim_epoch == released.claim_epoch
      assert row.attempts == %{}
      assert :ok = Placement.claimable(runner.tenant_id, story.id)

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
      assert session_dispatch(runner.tenant_id, story.id).revoked_at
    end

    # #877 review round 2, findings 4 and 10. The production ceiling is 0, so a refusal counted
    # by mistake escalates a story to a human on its FIRST occurrence. The table is written HERE,
    # not read off the module: deleting an entry from `@runner_unavailable` must turn one of
    # these red, which iterating the module's own list could never do. The call-site halves —
    # that `release_claim/5` passes this cause on, uncounted or counted — are the
    # `runner_not_connected` test above and the `{:invalid, _}` test below; what each cause does
    # to `attempts` is `stages_test.exs`'s.
    @uncounted_refusals [
      # the runner, not the story
      :runner_not_connected,
      :runner_ambiguous,
      :runner_at_capacity,
      :admission_limit_reached,
      :capacity_busy,
      :busy,
      :tenant_halted,
      # the runner's credential, bounded by the channel's authorization recheck
      :not_authorized,
      # a race the next pass does not meet again
      :stale_claim_epoch,
      # the machine's subscription ran dry after the pre-claim check (US-44.6)
      :runner_exhausted
    ]

    test "every runner-unavailable or race refusal is released uncounted; others count" do
      for reason <- @uncounted_refusals do
        assert {reason, Placement.release_cause(reason)} == {reason, :placement_refused}
      end

      # Every pass mints a fresh `dispatch_id`, so neither ledger fence can be another pass
      # having got there first (#877 review round 3): they are about THIS dispatch, and count.
      for reason <- [:dispatch_already_replied, :dispatch_id_conflict] do
        assert {reason, Placement.release_cause(reason)} == {reason, :attempt}
      end

      # Unlisted, and deterministic: the runner will refuse this kind on every pass.
      assert Placement.release_cause(:kind_not_supported) == :attempt
      assert Placement.release_cause({:invalid, ["wall_clock_seconds is too large"]}) == :attempt
    end

    # #877 review round 1, finding 3. A refusal that RECURS every pass — here a payload the
    # contract rejects, which `Runners.dispatch/3` casts only after the claim committed — is
    # not the runner being unavailable. (`max_turns`, not `wall_clock_seconds`: US-44.5 checks
    # the wall clock BEFORE the claim, so an oversized one never reaches a release at all.)
    # Uncounted, the driver placed it, was refused and released it on every pass for ever;
    # counted, the retry ceiling puts it in front of a human. The `runner_not_connected` test
    # above is the uncounted half (`attempts == %{}`).
    test "a refusal that recurs every pass COUNTS toward the retry ceiling", ctx do
      %{runner: runner, story: story} = ctx

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:invalid, [_ | _]}} =
                 place(
                   ctx,
                   Map.put(build(:placement_dispatch, %{"story_id" => story.id}), "max_turns", 0)
                 )
      end)

      # Below the ceiling of 2 (config/test.exs): counted once, and back in the queue.
      row = Stages.get(runner.tenant_id, story.id)
      assert {row.stage, row.attempts} == {:queued, %{"claim_released" => 1}}
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
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
      %{dispatch: parent, api_key: parent_key} = orchestrator(runner.tenant_id)

      disconnect(channel, runner)

      assert {:error, :runner_not_connected} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}),
                 api_key: parent_key
               )

      session = session_dispatch(runner.tenant_id, story.id)
      assert session.revoked_at

      assert [entry] = revoked_entries(runner.tenant_id, session.id)
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
    # NO MOCK CAN, BUT A TRIGGER CAN, and "a release that genuinely FAILED escalates" in
    # `Loopctl.Delivery.PlacementFaultTest` does exactly that. Round 1 of #865 left this gap
    # open and said so; the comment here used to name `bin/mutate.sh` as what joined the two
    # halves, which was a join that existed only
    # while somebody ran that one mutation by hand. The call site in `undo_claim/5` and the
    # two-clause condition over `release` are now asserted by a test.
    test "a release that SUCCEEDED escalates nothing", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      disconnect(channel, runner)

      log =
        OwnLog.capture_naming(story.id, fn ->
          assert {:error, :runner_not_connected} =
                   place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
        end)

      # NEITHER escalation log line, which is one assertion covering both branches: a story
      # whose claim went back is at `queued`, and `:session_escalated` leaves
      # `@in_flight ++ [:merged, :deployed]` — `queued` is in none of them — so an escalation
      # that fired here would not move the row at all and would only be visible as the LOUD
      # "COULD NOT ESCALATE" error. Asserting on the row alone could not see it.
      refute log =~ "ESCALATE"

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :queued
      assert is_nil(row.escalation_reason)
    end

    test "a claim the undo could not give back is PARKED for a human", ctx do
      %{runner: runner, story: story} = ctx

      # A REAL placement, so the story is genuinely `assigned` at stage `claimed` with a live
      # session dispatch recorded on it — the state a failed release leaves behind, built the
      # only way it can actually arise.
      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed

      log =
        OwnLog.capture_naming(story.id, fn ->
          assert :ok =
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     :runner_not_connected,
                     :not_found,
                     actor_label: "test"
                   )
        end)

      row = Stages.get(runner.tenant_id, story.id)
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

      # AND THE FIRST REMEDY NAMES ITS PRECONDITION, which is the half that was missing: the
      # orchestrator key that ran `place/4` produced this escalation and is the likeliest
      # reader of it, and `stage/resolve` refuses that key three times over (`RequireRole,
      # role: :user`, `RequireHumanAnchor`, then `Stages.human?/1` wanting
      # `actor_lineage == []`). A remedy an operator is structurally unable to perform, named
      # without saying so, is the same defect the `refute` above exists for.
      assert row.escalation_reason =~ "403 insufficient_role"
      assert row.escalation_reason =~ "minted by no dispatch"

      # And it is LOOPCTL'S OWN WORDS carrying loopctl's own error terms — there is no path
      # here by which session-authored text reaches an append-only chain entry.
      assert row.escalation_reason =~ "placement_error=:runner_not_connected"
      assert row.escalation_reason =~ "release_error=:not_found"

      # THE CLAIM IS STILL STANDING. This parks the story; it does not pretend to have freed
      # it — freeing it is what just failed. `resolve_escalation` to `queued` is the one call
      # that does both, which is why the reason names it first.
      still_held = reload(runner.tenant_id, story.id)
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

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Placement.escalate_unreleased_claim(
                   runner.tenant_id,
                   claimed,
                   session,
                   :runner_not_connected,
                   :not_found,
                   []
                 )
      end)

      assert Stages.get(runner.tenant_id, story.id).stage == :escalated

      assert {:ok, freed} =
               Progress.force_unclaim_story(runner.tenant_id, story.id, actor_label: "test")

      # THE CLAIM IS GONE — that half of the remedy is real and the reason still names it.
      assert freed.agent_status == :pending
      assert is_nil(freed.assigned_agent_id)

      # AND THE ESCALATION IS NOT. The row took the new epoch (a rebind) and kept its stage.
      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :escalated
      assert row.claim_epoch == freed.claim_epoch

      # SO CONTRACTING IT IS NOT A WAY BACK, which is exactly what the old wording promised it
      # was: an escalated stage is HELD (`Stages.held_story_ids/2`), so the contract itself is
      # refused, and only a human resolution to `queued` makes the story placeable again.
      assert {:error, :story_held} =
               Progress.contract_story(runner.tenant_id, story.id, %{},
                 actor_label: "test",
                 skip_contract_check: true
               )

      assert {:error, :wrong_stage} =
               Placement.claimable(runner.tenant_id, story.id)
    end

    test "the park is attributed to the PLACEMENT CALLER, not to the session that never ran",
         ctx do
      %{runner: runner, story: story} = ctx
      %{dispatch: parent, api_key: parent_key} = orchestrator(runner.tenant_id)

      # A LINEAGED caller, deliberately: with the default operator key the session dispatch is
      # a ROOT, so `Enum.drop(lineage_path, -1)` is `[]` and the correct value would equal the
      # value a defaulted-lineage defect writes. A parent is what makes the two differ.
      assert {:ok, _placed} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}),
                 api_key: parent_key
               )

      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Placement.escalate_unreleased_claim(
                   runner.tenant_id,
                   claimed,
                   session,
                   :runner_not_connected,
                   :not_found,
                   []
                 )
      end)

      # Entering `escalated` is CHAINED, so this writes an immutable entry naming an actor.
      # The session was minted and never ran, so recording ITS lineage would say a session
      # asked for a human when no session existed; the principal that acted is the one that
      # asked for the placement, which is what `release_claim/5` and `revoke_session_dispatch/3`
      # already record for their own compensations.
      assert [entry] = escalated_entries(runner.tenant_id, story.id)
      assert entry.actor_lineage == Enum.drop(session.lineage_path, -1)
      assert entry.actor_lineage == parent.lineage_path
      refute entry.actor_lineage == session.lineage_path
    end

    test "a stage with no escalation edge is reported stranded, and nothing is written", ctx do
      %{runner: runner, story: story} = ctx

      # `enter_claimed_and_push/6` also reaches its `else` when the `queued -> claimed` advance
      # itself was refused — a story that is CLAIMED while its row is still at `queued`, which
      # `:session_escalated` cannot leave. Staged here by claiming without advancing the row.
      claimed = claim_without_advancing(runner, story)
      session = session_dispatch(runner.tenant_id, story.id)

      log =
        OwnLog.capture_naming(story.id, fn ->
          assert :ok =
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     :busy,
                     :not_found,
                     []
                   )
        end)

      # NAMED, not reported as a bare `:invalid_transition` an operator has to decode — and
      # loud, because this is the story that is neither placeable nor parked.
      assert log =~ "COULD NOT ESCALATE"
      assert log =~ "no_escalation_edge"
      assert log =~ "force-unclaim"

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :queued
      assert is_nil(row.escalation_reason)
    end

    test "a claim epoch that has moved refuses the park rather than taking somebody else's",
         ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      # The fence, and the reason the epoch is the CLAIM's and is never re-read: a compensation
      # holding a spent epoch must not park a story whose claim has since gone back and been
      # re-taken. Staged by handing it an epoch the row will not match.
      stale = %{claimed | claim_epoch: claimed.claim_epoch - 1}

      log =
        OwnLog.capture_naming(story.id, fn ->
          assert :ok =
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     stale,
                     session,
                     :runner_not_connected,
                     :not_found,
                     []
                   )
        end)

      assert log =~ "COULD NOT ESCALATE"
      assert log =~ "stale_claim_epoch"

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :claimed
      assert is_nil(row.escalation_reason)
    end

    test "a pathological error term cannot lose the escalation", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

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
                 Placement.escalate_unreleased_claim(
                   runner.tenant_id,
                   claimed,
                   session,
                   :runner_not_connected,
                   %RuntimeError{message: huge},
                   []
                 )
      end)

      row = Stages.get(runner.tenant_id, story.id)
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

    test "an error term whose size is its ELEMENT COUNT cannot lose the escalation", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      # THE OTHER AXIS, and the one the test above cannot see. That one uses a single 20 KB
      # binary, which `:printable_limit` bounds by itself — so it holds `:limit` to nothing,
      # and opening `limit: 5` to `limit: :infinity` left the whole file green. Here the size
      # comes from the COUNT of elements instead, every one of them well under the printable
      # cap: a changeset carrying 40 errors of 500 characters, which is what
      # `Progress.force_unclaim_story/3` hands back on its `{:error, :story, changeset, _}`
      # branch. It arrives wrapped in `{:error, _}` and only on the release side, so passing it
      # BARE and on BOTH sides is deliberately the pessimistic form of the real shape: the
      # wrapper would spend limit budget of its own, and a real `placement_error` is a refusal
      # atom or `{:invalid, [binary]}`.
      #
      # Unbounded, one of these renders 18_823 codepoints against a 4_000 bound, so
      # `Stages.advance/4` refuses `:invalid_reason` BEFORE the transition and the story is
      # left neither placeable nor parked — the outcome this whole path exists to prevent.
      errors =
        for i <- 1..40,
            do: {:"field_#{i}", {String.duplicate("x", 500), [validation: :required]}}

      fat = %Ecto.Changeset{
        action: nil,
        changes: Map.new(errors, fn {field, _} -> {field, String.duplicate("x", 500)} end),
        errors: errors,
        data: %{},
        types: %{},
        valid?: false
      }

      log =
        OwnLog.capture_naming(story.id, fn ->
          assert :ok =
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     fat,
                     fat,
                     []
                   )
        end)

      assert log =~ "the story is ESCALATED"
      refute log =~ "COULD NOT ESCALATE"

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :escalated

      # AND THAT ASSERTION IS ALSO THE HEADROOM CHECK, which is why there is no separate
      # `String.length(...) <= max_reason_length()` line here: there could never be one that
      # fails on its own. `Stages.advance/4` REFUSES an over-long reason with `:invalid_reason`
      # before the transition, so a reason past the bound produces no escalation at all and no
      # `escalation_reason` to measure — the stage assertion goes red first, every time.
      #
      # So beyond `:limit`, this is what guards the PROSE: an edit that grows
      # `unreleased_claim_reason/2` past what is left of the 4_000 fails HERE rather than
      # losing a park in production, and that is why the whole-text clamp was not restored —
      # a clamp would absorb exactly that edit, silently. No codepoint budget is quoted: the
      # figure moved every time somebody stated it, and this assertion is what actually holds
      # the bound.
      assert row.escalation_reason =~ "resolve_escalation"

      # BOTH DIAGNOSTICS SURVIVED, not just the remedy: the pair fits, so an operator still
      # gets the shape of each error rather than one of them at the cost of the other.
      assert row.escalation_reason =~ "placement_error=#Ecto.Changeset<"
      assert row.escalation_reason =~ "release_error=#Ecto.Changeset<"
    end

    test "an explicit actor_label: nil mislabels the park rather than losing it", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      # A PRESENT KEY WITH A nil VALUE, which is the one input `Keyword.get/3` cannot defend
      # against: the default applies only when the key is ABSENT, so `nil <> @compensation_suffix`
      # raises, `escalate_unreleased_claim/6`'s rescue swallows it, and `log_park/6` takes the
      # loud branch — leaving the story held at `claimed` with a log line, which is the incident
      # this feature exists to end. `compensation_actor/1`'s `case` is what keeps the worst case
      # at a mislabelled park instead of no park at all. Every other test here passes a binary
      # or `[]`, so nothing else reaches this clause.
      log =
        OwnLog.capture_naming(story.id, fn ->
          assert :ok =
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     claimed,
                     session,
                     :runner_not_connected,
                     :not_found,
                     actor_label: nil
                   )
        end)

      assert log =~ "the story is ESCALATED"
      refute log =~ "COULD NOT ESCALATE"

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :escalated

      # AND IT IS STILL ATTRIBUTED. A caller that named no usable label falls back to
      # `@escalation_actor`, and the suffix is what tells this park apart from the story-object
      # park in the escalated queue.
      assert [event] = escalation_events(runner.tenant_id, story.id)
      assert event.actor_label == "control:placement/unreleased-claim"
    end

    test "a raise inside the park does not replace the refusal the caller is owed", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      # `Stages.get/2` and the chain append run on pools with no `lock_timeout` of their own,
      # so a DBConnection error here is a RAISE rather than an `{:error, _}` — the same shape
      # `release_claim/5` rescues for the same reason. Unrescued, it would replace the PUSH
      # refusal `place/4` owes its caller with a second, unrelated exception, and the caller
      # would never learn why its dispatch was refused. Staged with an unusable story id,
      # which is the cheapest thing that raises inside the first step.
      log =
        OwnLog.capture_naming(session.id, fn ->
          assert :ok =
                   Placement.escalate_unreleased_claim(
                     runner.tenant_id,
                     %{claimed | id: "not-a-uuid"},
                     session,
                     :runner_not_connected,
                     :not_found,
                     []
                   )
        end)

      # Keyed on the session: the line names the unusable story id, not this story's.
      assert log =~ "COULD NOT ESCALATE"

      # And it changed nothing on the way past.
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed
    end

    test "a story already parked is left exactly as it is, and is not parked twice", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)

      park = fn ->
        Placement.escalate_unreleased_claim(
          runner.tenant_id,
          claimed,
          session,
          :runner_not_connected,
          :not_found,
          []
        )
      end

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = park.() end)
      first = Stages.get(runner.tenant_id, story.id)

      # A REPEAT — a retried placement, or a node that died between the advance and the
      # return. `escalated` has no `:session_escalated` edge leaving it, so nothing is
      # attempted at all and `StoryPayload.settle_if_parked/3` reads the row as the outcome
      # this call wanted: no second `attempts` count, no second chain entry.
      repeat_log = OwnLog.capture_naming(story.id, fn -> assert :ok = park.() end)
      second = Stages.get(runner.tenant_id, story.id)

      # AND IT IS REPORTED AS THE OUTCOME IT IS, not as a failure to reach it. That is
      # `StoryPayload.settle_if_parked/3` doing its job: without the re-read this would take
      # the loud "COULD NOT ESCALATE" branch on a story that is parked, which is exactly the
      # noise that trains an operator to skip the line that matters.
      assert repeat_log =~ "the story is ESCALATED"
      refute repeat_log =~ "COULD NOT ESCALATE"

      assert second.stage == :escalated
      assert second.lock_version == first.lock_version
      assert second.attempts == first.attempts
      assert length(escalated_entries(runner.tenant_id, story.id)) == 1
    end

    test "a payload with no usable dispatch_id is refused before anything is claimed", ctx do
      %{runner: runner, story: story} = ctx

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "dispatch_id",
          "not-a-uuid"
        )

      assert {:error, {:invalid, ["dispatch_id: must be a UUID"]}} = place(ctx, payload)

      untouched = reload(runner.tenant_id, story.id)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
    end
  end

  describe "the claim's lease is capped at the dispatch deadline (#879, US-44.5)" do
    # TC-44.5.1: wall clock 3600 (the fixture's) and grace 900 (config/test.exs), so the cap is
    # placed_at + 4500s. `placed_at` is taken inside `place/4`, so it is bracketed here.
    test "the placed claim carries the cap, and claimed_until is the cap", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})
      assert payload["wall_clock_seconds"] == 3_600

      before = DateTime.utc_now()
      assert {:ok, _placed} = place(ctx, payload)
      after_place = DateTime.utc_now()

      claimed = reload(runner.tenant_id, story.id)
      assert %DateTime{} = cap = claimed.claim_lease_cap
      assert claimed.claimed_until == cap

      assert DateTime.compare(cap, DateTime.add(before, 4_500, :second)) in [:gt, :eq]
      assert DateTime.compare(cap, DateTime.add(after_place, 4_500, :second)) in [:lt, :eq]
    end

    # TC-44.5.6: the runner stops the session at the instant control's lease ends.
    test "the pushed dispatch carries deadline_at equal to the claim's cap", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", pushed, @reply_timeout

      cap = reload(runner.tenant_id, story.id).claim_lease_cap
      assert %DateTime{} = cap
      assert deadline(pushed) == cap
    end

    test "a caller-supplied deadline_at is REPLACED with the claim's own", ctx do
      %{runner: runner, story: story} = ctx

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "deadline_at",
          "2099-01-01T00:00:00Z"
        )

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout

      cap = reload(runner.tenant_id, story.id).claim_lease_cap
      assert deadline(pushed) == cap
    end

    test "a RESUME re-sends the claim's own deadline, never a caller's", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout

      assert {:ok, _resumed} =
               Placement.place(
                 runner.tenant_id,
                 runner.id,
                 Map.put(payload, "deadline_at", "2099-01-01T00:00:00Z"),
                 api_key: ctx.operator
               )

      assert_push "dispatch", again, @reply_timeout
      assert DateTime.compare(deadline(again), deadline(first)) in [:gt, :eq]
      assert {cap, cap} = sandboxed_lease(runner.tenant_id, story.id)
      assert deadline(again) == cap
    end

    # US-44.5 review round 3, finding 1. A resume sent the cap as it stood, so a LATE resume —
    # most of the claim-time cap already spent — carried a deadline that cut its session short.
    # It now moves the cap to now + wall clock + grace before pushing, and audits the move.
    test "a LATE resume carries a deadline from now, and the move is audited", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout
      nearly_spent = DateTime.add(DateTime.utc_now(), 60, :second)
      force_lease(runner.tenant_id, story.id, nearly_spent)

      before = DateTime.utc_now()
      assert {:ok, _resumed} = resume(ctx, payload)
      after_resume = DateTime.utc_now()

      assert_push "dispatch", again, @reply_timeout
      assert_between(deadline(again), before, after_resume, 3_600 + 900)
      assert sandboxed_lease(runner.tenant_id, story.id) == {deadline(again), deadline(again)}

      assert [entry] = sandboxed_reanchors(runner.tenant_id, story.id)
      assert entry.old_state["claim_lease_cap"] == DateTime.to_iso8601(nearly_spent)
      assert entry.new_state["claim_lease_cap"] == DateTime.to_iso8601(deadline(again))
    end

    # ...and a LONGER resume gets its whole clock rather than the first push's.
    test "a LONGER resume carries a deadline on its own wall clock", ctx do
      %{story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout

      before = DateTime.utc_now()
      assert {:ok, _resumed} = resume(ctx, Map.put(payload, "wall_clock_seconds", 7_200))
      after_resume = DateTime.utc_now()

      assert_push "dispatch", again, @reply_timeout
      assert_between(deadline(again), before, after_resume, 7_200 + 900)
      assert DateTime.compare(deadline(again), deadline(first)) == :gt
    end

    # A claim that has ENDED is not revived by a resume: refused, nothing pushed, nothing moved.
    test "a resume after the claim's lease ran out is refused dispatch_claim_ended", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout
      spent = DateTime.add(DateTime.utc_now(), -60, :second)
      force_lease(runner.tenant_id, story.id, spent)

      assert {:error, :dispatch_claim_ended} = resume(ctx, payload)

      refute_push "dispatch", _pushed, 200
      assert sandboxed_lease(runner.tenant_id, story.id) == {spent, spent}
      assert sandboxed_reanchors(runner.tenant_id, story.id) == []
    end

    # The claim-time cap is PROVISIONAL: the runner's wall clock starts at its acceptance,
    # which is also where `Capacity` anchors the session's bound, so the acceptance moves the
    # cap (and the lease) to replied_at + wall clock + grace.
    test "the runner's acceptance moves the cap to replied_at + wall clock + grace", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout
      provisional = reload(runner.tenant_id, story.id).claim_lease_cap

      {record, {claimed_until, cap}} = accept(runner, placed)
      assert record.wall_clock_seconds == 3_600

      assert cap == DateTime.add(record.replied_at, 4_500, :second)
      assert claimed_until == cap
      assert DateTime.compare(cap, provisional) == :gt
    end

    # A resume may carry a different wall clock; the push that wins records it, and the
    # acceptance re-anchors the cap on THAT clock rather than the one the claim was taken with.
    test "a RESUME with a longer wall clock, accepted later, is capped on the resumed clock",
         ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout

      assert {:ok, _resumed} =
               Placement.place(
                 runner.tenant_id,
                 runner.id,
                 Map.put(payload, "wall_clock_seconds", 7_200),
                 api_key: ctx.operator
               )

      assert_push "dispatch", again, @reply_timeout
      assert again.wall_clock_seconds == 7_200

      {record, {claimed_until, cap}} = accept(runner, placed)
      assert record.wall_clock_seconds == 7_200

      assert cap == DateTime.add(record.replied_at, 7_200 + 900, :second)
      assert claimed_until == cap
    end

    # US-44.5 review round 2, finding 2. A resume may push a SHORTER clock while the session
    # the first frame started still runs under the longer one — and the acceptance that then
    # arrives may be that first session's. Re-anchored on the latest push's 600 seconds, the
    # cap would not move at all (replied_at + 1 500 is before placed_at + 4 500) and the claim
    # would end with the first session's capacity still presumed busy; on the longest clock
    # any push carried, it moves to replied_at + 3 600 + grace.
    test "a RESUME with a SHORTER wall clock re-anchors on the longest clock any push carried",
         ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout

      assert {:ok, _resumed} =
               Placement.place(
                 runner.tenant_id,
                 runner.id,
                 Map.put(payload, "wall_clock_seconds", 600),
                 api_key: ctx.operator
               )

      assert_push "dispatch", again, @reply_timeout
      assert again.wall_clock_seconds == 600

      {record, {claimed_until, cap}} = accept(runner, placed)
      assert record.wall_clock_seconds == 600
      assert record.wall_clock_seconds_max == 3_600

      assert cap == DateTime.add(record.replied_at, 3_600 + 900, :second)
      assert claimed_until == cap
    end

    test "a RESUME runs the same wall clock rule and refuses an out-of-range clock", ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout
      over = Loopctl.ApiSpec.RunnerContract.RunnerDispatch.max_wall_clock_seconds() + 1

      assert {:error, {:invalid, ["wall_clock_seconds must be an integer from 1 to " <> _]}} =
               Placement.place(
                 runner.tenant_id,
                 runner.id,
                 Map.put(payload, "wall_clock_seconds", over),
                 api_key: ctx.operator
               )

      refute_push "dispatch", _pushed, 200
    end

    test "a wall clock the cap cannot be computed from is refused before anything is minted",
         ctx do
      %{runner: runner, story: story} = ctx
      before = tenant_dispatch_count(runner.tenant_id)
      over = Loopctl.ApiSpec.RunnerContract.RunnerDispatch.max_wall_clock_seconds() + 1

      for bad <- [0, over, "60s", 3_600.0, nil] do
        payload =
          Map.put(
            build(:placement_dispatch, %{"story_id" => story.id}),
            "wall_clock_seconds",
            bad
          )

        assert {:error, {:invalid, ["wall_clock_seconds must be an integer from 1 to " <> _]}} =
                 place(ctx, payload),
               "wall_clock_seconds #{inspect(bad)} was not refused before the claim"
      end

      assert tenant_dispatch_count(runner.tenant_id) == before
      untouched = reload(runner.tenant_id, story.id)
      assert untouched.agent_status == :contracted
      assert untouched.claim_lease_cap == nil
      refute_push "dispatch", _pushed, 200
    end

    # The cast `Runners.dispatch/3` runs coerces a decimal string, so the pre-claim check does
    # too: the cap and the pushed value are then the same integer.
    test "a decimal-string wall clock is placed and capped as the integer it names", ctx do
      %{runner: runner, story: story} = ctx

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "wall_clock_seconds",
          "3600"
        )

      before = DateTime.utc_now()
      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.wall_clock_seconds == 3_600

      cap = reload(runner.tenant_id, story.id).claim_lease_cap
      assert_in_delta DateTime.diff(cap, before), 4_500, 10
    end

    test "the longest wall clock the contract allows is still placed", ctx do
      %{runner: runner, story: story} = ctx
      max = Loopctl.ApiSpec.RunnerContract.RunnerDispatch.max_wall_clock_seconds()

      payload =
        Map.put(build(:placement_dispatch, %{"story_id" => story.id}), "wall_clock_seconds", max)

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      claimed = reload(runner.tenant_id, story.id)
      assert_in_delta DateTime.diff(claimed.claim_lease_cap, DateTime.utc_now()), max + 900, 10
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
               :deadline_at,
               :dispatch_id,
               :kind,
               :max_turns,
               :repo,
               :review,
               :story,
               :story_id,
               :token_budget,
               :triage,
               :wall_clock_seconds
             ]

      # `review` (contract 1.21.0, US-45.3) is the third nested object, and the reason a review
      # is a runner dispatch at all: it names WHAT to read and carries no credential to write
      # with. Every field is loopctl's own id, round number or sha; the review's findings and
      # verdict go back over the socket the runner already holds.
      assert RunnerContract.RunnerReview.schema().properties |> Map.keys() |> Enum.sort() == [
               :checkpoint_id,
               :checkpoint_seq,
               :commit_sha,
               :review_id,
               :round,
               :tree_sha
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
  # `deadline_at` as the channel pushed it. The cast (`format: :"date-time"`) makes it a
  # `DateTime`; normalised so the comparison is to an instant, not to one spelling of it.
  defp deadline(%{deadline_at: %DateTime{} = at}), do: at

  defp deadline(%{deadline_at: at}) when is_binary(at) do
    {:ok, parsed, 0} = DateTime.from_iso8601(at)
    parsed
  end

  # A RESUME: `place/4` again under a `dispatch_id` the ledger already holds.
  defp resume(ctx, payload) do
    Placement.place(ctx.runner.tenant_id, ctx.runner.id, payload, api_key: ctx.operator)
  end

  # A claim's lease and cap, both set to `at` (the CHECK requires the lease within
  # the cap, and a capped claim's lease always equals it).
  defp force_lease(tenant_id, story_id, at) do
    {1, _} =
      from(s in Story, where: s.tenant_id == ^tenant_id and s.id == ^story_id)
      |> AdminRepo.update_all(set: [claimed_until: at, claim_lease_cap: at])
  end

  # The story's lease and cap, read through `Repo` under the tenant's RLS context, where a
  # resume's re-anchor writes.
  defp sandboxed_lease(tenant_id, story_id) do
    {:ok, lease} =
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        Loopctl.Repo.one!(
          from s in Story,
            where: s.tenant_id == ^tenant_id and s.id == ^story_id,
            select: {s.claimed_until, s.claim_lease_cap}
        )
      end)

    lease
  end

  defp sandboxed_reanchors(tenant_id, story_id) do
    {:ok, entries} =
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        Loopctl.Repo.all(
          from a in Loopctl.Audit.AuditLog,
            where: a.tenant_id == ^tenant_id and a.entity_id == ^story_id,
            where: a.action == "claim_lease_reanchored"
        )
      end)

    entries
  end

  # `at` is `seconds` after some instant in [from, to].
  defp assert_between(%DateTime{} = at, from, to, seconds) do
    assert DateTime.compare(at, DateTime.add(from, seconds, :second)) in [:gt, :eq]
    assert DateTime.compare(at, DateTime.add(to, seconds, :second)) in [:lt, :eq]
  end

  # The runner's `accepted` reply, recorded as the channel records it, and the ledger row and
  # the story's `{claimed_until, claim_lease_cap}` after it.
  defp accept(runner, placed) do
    {:ok, reply} =
      RunnerContract.cast_dispatch_reply(%{
        "dispatch_id" => placed.dispatch_id,
        "claim_epoch" => placed.claim_epoch,
        "decision" => "accepted"
      })

    {:ok, record} = DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)

    {:ok, lease} =
      Loopctl.Repo.with_tenant(runner.tenant_id, fn ->
        Loopctl.Repo.one!(
          from s in Story,
            where: s.tenant_id == ^runner.tenant_id and s.id == ^record.story_id,
            select: {s.claimed_until, s.claim_lease_cap}
        )
      end)

    {DispatchLedger.get_record(runner.tenant_id, placed.dispatch_id), lease}
  end

  defp place(ctx, payload, opts \\ []) do
    %{runner: runner, operator: operator} = ctx
    opts = Keyword.merge([api_key: operator], opts)
    Placement.place(runner.tenant_id, runner.id, payload, opts)
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

  defp tenant_dispatch_count(tenant_id) do
    AdminRepo.aggregate(from(d in Dispatch, where: d.tenant_id == ^tenant_id), :count, :id)
  end

  # A branch the caller named that satisfies everything except what the test is probing: the
  # story's suffix behind a prefix of the caller's choosing.
  defp caller_branch(story, prefix), do: prefix <> DispatchPayload.story_suffix(story)

  # The runner drops its socket and joins again declaring `overrides`. A capacity or draining
  # declaration is per-CONNECTION, so this is the only way to change one.
  defp rejoin(ctx, overrides) do
    %{runner: runner, channel: channel, runner_key: raw} = ctx
    disconnect(channel, runner)

    {:ok, socket} =
      connect(RunnerSocket, %{}, connect_info: build(:runner_connect_info, %{token: raw}))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> runner.id,
        Map.merge(build(:runner_join_payload, %{"machine" => "minis"}), overrides)
      )

    _ = :sys.get_state(channel.channel_pid)
    channel
  end

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
  defp bind_repo(tenant_id, story, repo, mode \\ :pr) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Loopctl.Intake.Source{
      tenant_id: tenant_id,
      project_id: story.project_id,
      repo_full_name: repo,
      base_branch: "master",
      mode: mode,
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })
  end

  defp escalated_entries(tenant_id, story_id) do
    AdminRepo.all(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^story_id,
        where: e.action == "story_stage_escalated"
    )
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

  describe "a machine that declares it takes no work" do
    # #846.4 review findings 3 and 8. The contract tells runner authors that a machine wanting
    # no work declares `draining`, and that a `max_sessions` of 0 says the same thing. Until
    # these tests both statements were honoured only by the unattended SELECTORS
    # (`Runners.accepts?/5`): a placement naming the runner reached neither, so the contract's
    # advice was unactionable on the one path that CLAIMS THE STORY BEFORE IT PUSHES.
    test "draining is refused before anything is claimed", ctx do
      %{runner: runner, story: story} = ctx
      rejoin(ctx, %{"draining" => true})

      assert {:error, :runner_declines_work} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      # NOTHING WAS SPENT. Refused before the mint and the claim, so there is no compensation
      # to get right: the story is still queued and no session dispatch exists.
      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
      refute_push "dispatch", _pushed, @reply_timeout
    end

    test "a declared max_sessions of 0 is refused too, though the column holds 1", ctx do
      %{runner: runner, story: story} = ctx
      rejoin(ctx, %{"max_sessions" => 0})

      # The column is 1..64, so `declared_max_sessions/1` holds the 0 as a 1 (proved in
      # `Loopctl.Runners.CapacityTest`).
      # Without the meta being read at the DECISION, that clamp puts exactly ONE dispatch on a
      # machine that said it accepts none — which is what this refusal prevents.
      assert {:error, :runner_declines_work} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      refute_push "dispatch", _pushed, @reply_timeout
    end

    # #846.4 review ROUND 2, finding 1. The gate above sat in `place/4`'s own `with`, ahead of
    # the ledger lookup that routes a retry, so it applied to the RESUME path too — where
    # nothing is claimed by this call and the claim it re-pushes under is already standing.
    # A machine draining mid-connection is the ordinary graceful drain (finish what you hold,
    # take nothing new), so every in-flight dispatch on that machine was one lost frame away
    # from a 409 whose body says "Nothing was claimed. Place on another runner" — both halves
    # false, since the claim is live and the dispatch_id is spent. The story then sat at
    # `claimed` with no session until its lease expired, which is the outcome the gate exists
    # to prevent.
    test "a RESUME under the same dispatch_id is still pushed at a machine that went draining",
         ctx do
      %{runner: runner, story: story} = ctx
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout
      assert first.dispatch_id == payload["dispatch_id"]

      # THE CLAIM COMMITTED AND IS LIVE. Everything below is about work this machine already
      # holds, which is exactly what a draining machine is asked to finish.
      assert reload(runner.tenant_id, story.id).agent_status == :assigned

      rejoin(ctx, %{"draining" => true})

      # The SAME dispatch_id, which is what `place_dispatch`'s own description instructs after
      # a lost response or a dropped frame.
      assert {:ok, resumed} =
               Placement.place(runner.tenant_id, runner.id, payload, api_key: ctx.operator)

      assert resumed.dispatch_id == placed.dispatch_id
      assert resumed.claim_epoch == placed.claim_epoch

      assert_push "dispatch", again, @reply_timeout
      assert again.dispatch_id == payload["dispatch_id"]
      assert again.story.id == story.id

      # And the claim is untouched: a resume compensates nothing, because it took nothing.
      assert reload(runner.tenant_id, story.id).agent_status == :assigned
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed
    end

    test "a machine declaring neither is placed on as before", ctx do
      %{story: story} = ctx

      # Declaring the number the row ALREADY holds, deliberately, so the rejoin moves no
      # capacity and the placement below turns on the declaration alone.
      rejoin(ctx, %{"draining" => false, "max_sessions" => 2})

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout
    end
  end

  # STORY 846.2. The delivery loop's first real placement was refused `branch_not_allowed`:
  # loopctl derived `feature/story-<n>-<id>` and the minis runner's config accepted `loop/`
  # alone, so the dispatch was refused, the story was parked, and the run never started. The
  # one field was never the defect — loopctl chose a prefix, each operator chose a prefix per
  # machine, and nothing reconciled them.
  describe "a machine that declares the branch prefixes it accepts" do
    # AC-4, and the test AC-4 names its own mutation for: make the derivation ignore the
    # declared prefix and this goes red. It asserts on the frame the RUNNER receives, so it
    # binds the whole path — the declaration reaching the Presence meta, the placement reading
    # the sole live meta, and `DispatchPayload.fill/3` using it — rather than the derivation
    # in isolation, which `Loopctl.Delivery.DispatchPayloadTest` covers.
    test "the pushed branch starts with the prefix the runner declared", ctx do
      %{runner: runner, story: story} = ctx
      rejoin(ctx, %{"branch_prefixes" => ["loop/"]})

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.branch ==
               "loop/story-#{story.number}-#{String.slice(story.id, 0, 8)}"

      # AC-5: the prefix moved and the unique part did not. Without this a derivation that
      # returned the bare prefix would satisfy the assertion above.
      assert String.ends_with?(pushed.branch, String.slice(story.id, 0, 8))
      assert runner.name == "minis"
    end

    # AC-1, END TO END. The inertness claim is the whole safety of shipping this before any
    # runner declares the field, so it is asserted against the DERIVATION rather than against
    # a literal: whatever `branch_for/2` produces with no declaration is what an undeclaring
    # runner must be sent.
    test "a runner that declares nothing is sent exactly the branch it was sent before", ctx do
      %{story: story} = ctx
      rejoin(ctx, %{"draining" => false, "max_sessions" => 2})

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", pushed, @reply_timeout

      assert {:ok, unconstrained} = DispatchPayload.branch_for(story)
      assert pushed.branch == unconstrained
    end

    # AC-5 is not negotiable, so a declaration that leaves no room for a unique name is a
    # refusal. BEFORE the claim, like `runner_declines_work`: the runner would refuse the push
    # itself, and by then the story is claimed for it and sits at `claimed` until its lease
    # expires.
    test "a prefix that cannot produce a valid branch refuses before anything is claimed",
         ctx do
      %{runner: runner, story: story} = ctx
      rejoin(ctx, %{"branch_prefixes" => ["loop//"]})

      assert {:error, {:no_conforming_branch, ["loop//"]}} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
      refute_push "dispatch", _pushed, @reply_timeout
    end

    # A CALLER'S BRANCH IS JUDGED, NEVER REWRITTEN. Refused here it costs nothing; left to the
    # runner it costs the claim, which is the same failure this story exists to end wearing a
    # different hat.
    test "a caller-supplied branch outside the declaration is refused before the claim", ctx do
      %{runner: runner, story: story} = ctx
      rejoin(ctx, %{"branch_prefixes" => ["loop/"]})

      # UNIQUE but outside the declaration, so the refusal under test is the prefix one and
      # not `branch_not_unique`, which is judged first.
      outside = caller_branch(story, "feature/")
      payload = Map.put(build(:placement_dispatch, %{"story_id" => story.id}), "branch", outside)

      assert {:error, {:branch_not_allowed, ^outside, ["loop/"]}} = place(ctx, payload)
      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
      refute_push "dispatch", _pushed, @reply_timeout
    end

    test "a caller-supplied branch INSIDE the declaration is passed through untouched", ctx do
      %{story: story} = ctx
      rejoin(ctx, %{"branch_prefixes" => ["loop/"]})

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "branch",
          caller_branch(story, "loop/")
        )

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.branch == caller_branch(story, "loop/")
    end

    # SOUL RULE 9, THE RETRY QUESTION — and round 2 finding 4 REVERSED the answer this test
    # asserted. It used to say a retry MAY land on a different branch when the machine rejoined
    # declaring a different set, on the argument that a row still at `sent` means the first
    # frame was never accepted. `sent` means only that no reply was RECORDED, and a LOST REPLY
    # is exactly the case a resume exists for — so a session may be running on the first name
    # right now. `runner_dispatches.branch` records the name at the first push and the resume
    # re-sends THAT, which is the property this test now binds.
    #
    test "a RESUME re-sends the recorded name, even after the declaration moved", ctx do
      %{runner: runner, story: story} = ctx
      # THREADED, because `rejoin/2` disconnects the channel in the ctx it is given: a second
      # rejoin from the original ctx would drop an already-dead channel and leave the live
      # entry in the pool.
      ctx = %{ctx | channel: rejoin(ctx, %{"branch_prefixes" => ["loop/"]})}
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout
      assert String.starts_with?(first.branch, "loop/")

      # The operator changed the machine's configuration and it reconnected. A session may be
      # running on `loop/...` — the reply is merely not recorded.
      ctx = %{ctx | channel: rejoin(ctx, %{"branch_prefixes" => ["agent/"]})}

      assert {:ok, resumed} =
               Placement.place(runner.tenant_id, runner.id, payload, api_key: ctx.operator)

      assert resumed.dispatch_id == placed.dispatch_id
      assert resumed.claim_epoch == placed.claim_epoch

      assert_push "dispatch", again, @reply_timeout
      assert again.dispatch_id == payload["dispatch_id"]

      # THE NAME DID NOT MOVE. Not the new declaration's, not the un-prefixed default's.
      assert again.branch == first.branch
      assert again.branch == caller_branch(story, "loop/")
    end

    # THE LEDGER'S NAME IS NOT OVERWRITTEN BY A CALLER'S EITHER, and the disagreement is
    # refused rather than resolved: substituting silently would be the rewrite this module
    # forbids everywhere else, and accepting the caller's would put a second name on the wire
    # against a session that may be running on the first.
    test "a RESUME naming a DIFFERENT branch is refused, not silently substituted", ctx do
      %{runner: runner, story: story} = ctx
      ctx = %{ctx | channel: rejoin(ctx, %{"branch_prefixes" => ["loop/", "agent/"]})}
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout

      retry = Map.put(payload, "branch", caller_branch(story, "agent/"))

      assert {:error, {:branch_conflict, other, recorded}} =
               Placement.place(runner.tenant_id, runner.id, retry, api_key: ctx.operator)

      assert recorded == first.branch
      assert other == caller_branch(story, "agent/")
      refute_push "dispatch", _pushed, @reply_timeout

      # Nothing was written, so the same dispatch_id still resumes on the recorded name.
      assert {:ok, _resumed} =
               Placement.place(runner.tenant_id, runner.id, payload, api_key: ctx.operator)

      assert_push "dispatch", again, @reply_timeout
      assert again.branch == first.branch
    end

    # US-45.4 REVIEW ROUND 3, FINDING 3. The ledger row keeps the first push's `base_branch`
    # and the merge gate judges against it, so a resume must put THAT one on the wire, not
    # the intake source's current one. Without the pin a source repointed between placement
    # and resume sends the session to sync from a base the gate never judges against.
    test "a RESUME re-sends the recorded base branch after the source was repointed", ctx do
      %{runner: runner, story: story} = ctx
      source = bind_repo(runner.tenant_id, story, "mkreyman/pinned-base")
      payload = Map.delete(build(:placement_dispatch, %{"story_id" => story.id}), "base_branch")

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout
      assert first.base_branch == "master"

      assert {:ok, _} =
               Loopctl.Intake.update_source(runner.tenant_id, source.id, %{base_branch: "main"})

      assert {:ok, _resumed} =
               Placement.place(runner.tenant_id, runner.id, payload, api_key: ctx.operator)

      assert_push "dispatch", again, @reply_timeout
      assert again.base_branch == "master"
    end

    test "a RESUME naming a DIFFERENT base branch is refused", ctx do
      %{runner: runner, story: story} = ctx
      _source = bind_repo(runner.tenant_id, story, "mkreyman/pinned-base")
      payload = Map.delete(build(:placement_dispatch, %{"story_id" => story.id}), "base_branch")

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout

      retry = Map.put(payload, "base_branch", "main")

      assert {:error, {:base_branch_conflict, "main", "master"}} =
               Placement.place(runner.tenant_id, runner.id, retry, api_key: ctx.operator)

      refute_push "dispatch", _pushed, @reply_timeout
    end

    # The pool is where an operator looks at a machine that is connected and refusing
    # everything, so it is where the declaration has to be readable — the whole defect was
    # that these prefixes lived only in a config file on the target box.
    test "the pool echoes what the machine declared", ctx do
      %{runner: runner} = ctx
      rejoin(ctx, %{"branch_prefixes" => ["loop/", "feature/"]})

      assert [meta] = Runners.live_metas(runner.tenant_id, runner.id)
      assert Runners.declared_branch_prefixes(meta) == ["loop/", "feature/"]
    end

    test "a machine declaring neither prefixes nor anything else is placed on as before", ctx do
      %{story: story} = ctx

      # Declaring the number the row ALREADY holds, deliberately, so the rejoin moves no
      # capacity and the placement below turns on the declaration alone.
      rejoin(ctx, %{"draining" => false, "max_sessions" => 2})

      assert {:ok, _placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout
    end
  end

  # 846.2 REVIEW FINDINGS 1 AND 3. Two questions are asked about a caller's branch and they
  # are NOT the same question: what another MACHINE declared, and whether the STRING is a git
  # ref name. The first can strand a live claim on the resume path and is advisory there; the
  # second is a property of the request, is checked everywhere, and was checked nowhere at all
  # for a caller-supplied value — `branch_allowed?/2` returns true unconditionally against the
  # `[]` every runner in the fleet declares today, and `RunnerDispatch.branch` carries no
  # pattern on the wire.
  describe "the two refusals a branch can earn, and which of them a resume is exempt from" do
    # THE STRAND. The claim committed on the first call and is live; a `dispatch_id` is spent,
    # so no new placement can be made while it stands. Refused here, the story sits at
    # `claimed` with no session until its lease expires — the outcome the draining gate's own
    # comment calls "the exact outcome this gate exists to prevent".
    #
    # The sequence is the DOCUMENTED remediation: the operator fixed the machine's
    # configuration and it rejoined. Here the new declaration is one no valid branch can be
    # built from, which is what `:refuse` would have answered `no_conforming_branch` to.
    # `:advise` IS STILL REACHABLE, AND THIS IS WHERE IT IS REACHED. Since round 2 pinned the
    # branch to the ledger row, a resume normally never consults the declaration at all —
    # except for a row written BEFORE `runner_dispatches.branch` existed, which carries NULL
    # and must still fall back to deriving rather than refusing. Those rows are exactly the
    # ones that cannot do better, and exactly the ones a refusal would strand.
    #
    # ASSERTED AT `fill/3` RATHER THAN THROUGH A PUSH, deliberately: the policy is the thing
    # under test and `fill/3` is where it lives; the WIRING — that a
    # resume is not refused for a declaration that moved under it — is bound end to end by the
    # caller-branch test above, which would be `branch_not_allowed` under `:refuse`.
    test "the policy a pre-column resume falls back on derives instead of refusing", ctx do
      %{story: story, runner: runner} = ctx
      unsatisfiable = ["loop//"]
      payload = build(:placement_dispatch, %{"story_id" => story.id})

      assert {:error, {:no_conforming_branch, ^unsatisfiable}} =
               DispatchPayload.fill(runner.tenant_id, payload, branch_prefixes: unsatisfiable)

      assert {:ok, filled} =
               DispatchPayload.fill(runner.tenant_id, payload,
                 branch_prefixes: unsatisfiable,
                 prefix_policy: :advise
               )

      assert {:ok, unconstrained} = DispatchPayload.branch_for(story)
      assert filled["branch"] == unconstrained
    end

    # The same strand reached through the other refusal. `branch` was REQUIRED by the schema
    # before 1.14.0, so every client built against it names one, which makes this the likelier
    # half of the two.
    test "a RESUME is not refused when the caller's branch is outside the declaration", ctx do
      %{runner: runner, story: story} = ctx
      ctx = %{ctx | channel: rejoin(ctx, %{"branch_prefixes" => ["loop/"]})}

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "branch",
          caller_branch(story, "loop/")
        )

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", first, @reply_timeout
      assert first.branch == caller_branch(story, "loop/")

      _channel = rejoin(ctx, %{"branch_prefixes" => ["agent/"]})

      assert {:ok, resumed} =
               Placement.place(runner.tenant_id, runner.id, payload, api_key: ctx.operator)

      assert resumed.dispatch_id == payload["dispatch_id"]

      # NEVER REWRITTEN, on this path as on every other: the caller's own name goes back out.
      assert_push "dispatch", again, @reply_timeout
      assert again.branch == caller_branch(story, "loop/")

      assert reload(runner.tenant_id, story.id).agent_status == :assigned
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed
    end

    # FINDING 3, AND ROUND 2 FINDINGS 1 AND 2 — SWEPT OVER THE CONTRACT'S OWN LIST RATHER THAN
    # OVER A PAIR OF FIELD NAMES THIS TEST REMEMBERS.
    #
    # Round 1 asserted this for `branch`. Round 2 found `base_branch` open on the identical
    # schema one line above it, and a NON-STRING `branch` skipping the check entirely and
    # costing a claim. Enumerating a third spelling here would have left the same hole one
    # field further along, so the loop is over `RunnerDispatch.ref_fields/0`: a ninth
    # ref-shaped field is covered by this test the moment it is declared, and the contract
    # test refuses to let one be added without being declared.
    #
    # The runner declares NOTHING, which is every machine in the fleet today and the case
    # `branch_allowed?/2` passes unconditionally. Each of these values casts clean against the
    # wire schema (a string, 1..255, no pattern) and was pushed verbatim to a machine that
    # hands it to git: a leading `-` is read as an OPTION rather than a ref, which is this
    # change's own stated rationale for the join-side pattern.
    test "NO ref field a caller sends reaches a machine unvalidated, and none costs a claim",
         ctx do
      %{runner: runner, story: story} = ctx

      not_ref_names = ["--upload-pack=/bin/sh", "-o", "a..b", "loop/\n", "feature/x.lock"]
      not_strings = [nil, 7, %{}, [], true]

      for {field, _disposition} <- RunnerContract.RunnerDispatch.ref_fields(),
          bad <- not_ref_names ++ not_strings do
        payload =
          Map.put(build(:placement_dispatch, %{"story_id" => story.id}), to_string(field), bad)

        assert {:error, {:invalid_branch_name, ^field, ^bad}} = place(ctx, payload),
               "#{to_string(field)}=#{inspect(bad)} was accepted"
      end

      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert reload(runner.tenant_id, story.id).agent_status == :contracted
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
      refute_push "dispatch", _pushed, @reply_timeout
    end

    # ROUND 2 FINDING 1, STATED AS THE PROPERTY RATHER THAN AS A FIELD NAME. `base_branch` was
    # the leak round 1 left: identical schema, caller-supplied on this endpoint, and
    # `fill_repo/3` short-circuits on `Map.has_key?` so a caller's value beats the intake
    # source outright.
    test "base_branch is judged too, and a caller's value beating the intake source cannot " <>
           "smuggle an argument",
         ctx do
      %{runner: runner, story: story} = ctx

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "base_branch",
          "--upload-pack=/bin/sh"
        )

      assert {:error, {:invalid_branch_name, :base_branch, _}} = place(ctx, payload)
      assert Stages.get(runner.tenant_id, story.id).stage == :queued
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
      refute_push "dispatch", _pushed, @reply_timeout
    end

    # ROUND 2 FINDING 7. The contract publishes that two stories on one repository can never
    # share a branch, and that was true only of the DERIVED name: `branch_allowed?/2` checks
    # the prefix and nothing else, so two placements naming `loop/mine` both succeeded onto one
    # branch and the second session would find the first's work there. `branch` was REQUIRED
    # before 1.14.0, so every client built against that schema sends one.
    test "a caller's branch that drops the story's suffix is refused, prefix kept", ctx do
      %{runner: runner, story: story} = ctx
      rejoin(ctx, %{"branch_prefixes" => ["loop/"]})

      suffix = DispatchPayload.story_suffix(story)

      shared =
        Map.put(build(:placement_dispatch, %{"story_id" => story.id}), "branch", "loop/mine")

      assert {:error, {:branch_not_unique, :branch, "loop/mine", ^suffix}} = place(ctx, shared)
      assert session_dispatch_count(runner.tenant_id, story.id) == 0
      refute_push "dispatch", _pushed, @reply_timeout

      # The caller keeps its prefix. What it may not drop is the part that makes the name this
      # story's and nobody else's.
      kept =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "branch",
          caller_branch(story, "loop/")
        )

      assert {:ok, _placed} = place(ctx, kept)
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.branch == caller_branch(story, "loop/")
    end

    # `base_branch` IS NOT STORY-UNIQUE, and that is a decision rather than an omission: it is
    # the ref a session cuts FROM, deliberately shared by every dispatch in the tenant.
    # Requiring a suffix there would refuse `master`, which is the only value anyone sends.
    test "base_branch is shared, so an ordinary ref name is accepted", ctx do
      %{story: story} = ctx

      payload =
        Map.put(build(:placement_dispatch, %{"story_id" => story.id}), "base_branch", "main")

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.base_branch == "main"
    end

    # THE OTHER SIDE OF THE RESUME DECISION, and the reason the two refusals are not folded
    # into one exemption. The remedy for a malformed name is in this very request and the
    # refusal writes nothing, so the same `dispatch_id` is immediately retryable — while a
    # name git will not take could not have started a session on any machine anyway.
    test "a RESUME is still refused for a branch that is not a git ref name", ctx do
      %{runner: runner, story: story} = ctx
      ctx = %{ctx | channel: rejoin(ctx, %{"branch_prefixes" => ["loop/"]})}

      payload =
        Map.put(
          build(:placement_dispatch, %{"story_id" => story.id}),
          "branch",
          caller_branch(story, "loop/")
        )

      assert {:ok, _placed} = place(ctx, payload)
      assert_push "dispatch", _first, @reply_timeout

      retry = Map.put(payload, "branch", "-o")

      assert {:error, {:invalid_branch_name, :branch, "-o"}} =
               Placement.place(runner.tenant_id, runner.id, retry, api_key: ctx.operator)

      refute_push "dispatch", _pushed, @reply_timeout

      # Nothing was written, so the claim stands and the caller can retry the same
      # `dispatch_id` with a name that works.
      assert reload(runner.tenant_id, story.id).agent_status == :assigned
      assert Stages.get(runner.tenant_id, story.id).stage == :claimed

      assert {:ok, _resumed} =
               Placement.place(runner.tenant_id, runner.id, payload, api_key: ctx.operator)

      assert_push "dispatch", again, @reply_timeout
      assert again.branch == caller_branch(story, "loop/")
    end
  end

  # 846.2 REVIEW ROUND 2, FINDING 5. `Placement.place/4` returns whatever
  # `DispatchPayload.fill/3` returns, so the two `@type error()` unions are one declaration in
  # two files — and round 1 added `invalid_branch_name` to the payload's and not to the
  # placement's. Dialyzer does not catch it (measured: `bin/mutate.sh` on that union exits 1
  # against `mix dialyzer`, because the placement union already carries a bare `atom()` and
  # dialyzer only refuses a contract that is impossible, never one that is merely too narrow).
  # So the drift needs a test, and this is it: the next caller written against the DOCUMENTED
  # set falls through to the fallback controller and answers 500 on an ordinary refusal.
  describe "the error union Placement documents" do
    test "covers every error DispatchPayload can hand it" do
      missing = error_union(DispatchPayload) -- error_union(Placement)

      assert missing == [],
             "#{inspect(missing)} is returned by DispatchPayload.fill/3, which Placement.place/4 " <>
               "passes through, and is not in Placement's own @type error() — a caller written " <>
               "against the documented set has no clause for it and answers 500"
    end
  end

  # The members of a module's `@type error()` union, as strings, read off the compiled
  # typespec rather than by parsing source.
  defp error_union(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)
    {:type, spec} = Enum.find(types, fn {_kind, {name, _ast, _vars}} -> name == :error end)

    {:"::", _, [_head, union]} = Code.Typespec.type_to_quoted(spec)
    flatten_union(union)
  end

  defp flatten_union({:|, _, [left, right]}), do: flatten_union(left) ++ flatten_union(right)
  defp flatten_union(other), do: [Macro.to_string(other)]
end
