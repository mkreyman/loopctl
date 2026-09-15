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
