defmodule Loopctl.Delivery.PlacementFaultTest do
  @moduledoc """
  `Loopctl.Delivery.Placement.place/4` when a write it depends on FAILS (issue #803, 846.8):
  a dependency that appears between the pre-check and the claim, a release, a clear and a
  revoke that cannot write. And the committed-row sweep's own guarantee, which every
  committed-tenant module relies on.

  `async: false`, and COMMITTED, because each failure is injected with DDL: a trigger on
  `dispatches`, `story_stages` or `stories`, scoped to this test's rows. Nothing reachable
  from Elixir produces these failures (see `fail_the_release!/1`), and DDL on a shared table
  holds its lock until the transaction ends, so inside an async test's sandbox transaction it
  would stall every other test writing that table. The sweep test is about committed rows and
  a pooled connection by definition. So the rows are committed (`fixture(:committed_tenant)`
  and its siblings, then production's two connections, `Loopctl.Test.ProductionTopology`),
  every trigger is dropped on exit, and `sweep_committed_runner_tenants/0` removes the rows,
  chain entries included. Everything else about placement is
  `Loopctl.Delivery.PlacementTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Loopctl.Fixtures
  import Phoenix.ChannelTest

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.AuditChain
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.RunnerSocket

  @endpoint LoopctlWeb.Endpoint
  @reply_timeout 2_000

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of ChannelCase's stubs. Global mode is
    # safe in an `async: false` module, and the channel process reads the mocks too.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # HUMAN-ANCHORED explicitly: `place/4` applies the L0 tier gate itself, and the committed
    # tenant's column default is `:agent_rooted`. The committed fixtures run their own unboxed
    # checkout, so they go first; from the checkout on, every write of this process commits,
    # and the channel process, which inherits this process's `$callers`, writes on its
    # connection.
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    {_operator_raw, operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    story = fixture(:committed_story, %{tenant_id: runner.tenant_id})
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(raw))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)

    story = contract_and_queue(runner.tenant_id, story)

    %{runner: runner, channel: channel, story: story, operator: operator, runner_key: raw}
  end

  describe "place/4 when a write it depends on fails" do
    test "a claim that fails past the pre-check REVOKES the dispatch it minted", ctx do
      %{runner: runner, story: story} = ctx

      # The race `claimable/2` cannot close, made deterministic. The pre-check reads the story's
      # dependencies (#884), so the blocker is added AFTER it: a trigger inserts the dependency
      # when the session dispatch is minted, between the pre-check and the claim — which then
      # refuses. That is the one path on which a dispatch is minted for a claim that never
      # happens, so its ephemeral key must not be left live for its four-hour TTL.
      blocker = fixture(:ledger_story, %{tenant_id: runner.tenant_id})
      name = "test_dep_at_mint_" <> String.replace(story.id, "-", "")

      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO story_dependencies (id, tenant_id, story_id, depends_on_story_id, inserted_at)
        VALUES (gen_random_uuid(), NEW.tenant_id, '#{story.id}', '#{blocker.id}', now());
        RETURN NEW;
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} AFTER INSERT ON dispatches FOR EACH ROW
      WHEN (NEW.tenant_id = '#{runner.tenant_id}') EXECUTE FUNCTION #{name}()
      """)

      on_exit(fn ->
        :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON dispatches")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      assert {:error, :dependencies_not_met} = place(ctx, dispatch_payload(story))
      refute_push "dispatch", _pushed, 200

      session = session_dispatch(runner.tenant_id, story.id)
      assert session.revoked_at, "the minted dispatch was left live for a claim that failed"
      assert AdminRepo.get!(ApiKey, session.api_key_id).revoked_at

      untouched = reload(runner.tenant_id, story.id)
      assert untouched.agent_status == :contracted
      assert is_nil(untouched.implementer_dispatch_id)
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

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "release of that claim ALSO failed"
      assert row.escalation_reason =~ "resolve_escalation"

      # THE CLAIM IS STILL STANDING, which is the state this whole branch exists for and the
      # thing the trigger is scoped to produce: the Multi aborted at its `:stage` step, so the
      # `:story` write rolled back with it and the story is `assigned` at an in-flight stage
      # with a session that will never run. `implementer_dispatch_id` is gone because
      # `undo_claim/5`'s clear step runs on its own transaction and succeeded.
      held = reload(runner.tenant_id, story.id)
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
      assert [event] = escalation_events(runner.tenant_id, story.id)
      assert event.actor_label == "api:dispatch_placement/unreleased-claim"
      refute event.actor_label == "api:dispatch_placement"
    end

    # 846.8 REVIEW ROUND 2, finding 1. THE POSITION PROPERTY: `clear_if_revoked/4` runs THIRD
    # of `undo_claim/5`'s five statements, so anything that aborts it takes `log_undo/5` and
    # `park_unreleased_claim/6` with it — and neither `undo_claim/5` nor `place/4` rescues, so
    # the caller's real refusal is replaced by an exception and the story is left `claimed`
    # with NO HUMAN TOLD. That is the four-hour incident this branch exists to end, reached by
    # a different door.
    #
    # It is why the clear's `rescue` exists and why its third clause returns a tagged term
    # instead of crashing (`park_unreleased_claim/6` may crash; it is LAST). The property is
    # stated in comments at both places, and this is the test that holds it: the clear is made
    # to raise for real, and both things that follow it must still have happened.
    test "a clear that RAISES still leaves the caller its refusal and still escalates", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      # Release fails (so the park has something to escalate) AND the clear raises. The two
      # triggers are on different tables and different column transitions, so neither sees the
      # other's write: the release is `story_stages` claimed -> queued, the clear is `stories`
      # implementer_dispatch_id -> NULL.
      fail_the_release!(story.id)
      fail_the_clear!(story.id)
      disconnect(channel, runner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :runner_not_connected} =
                   place(ctx, dispatch_payload(story), actor_label: "api:dispatch_placement")
        end)

      # THE TWO STATEMENTS AFTER THE CLEAR BOTH RAN. `log_undo/5` reports the undo, and the
      # park escalated — which is the whole of what a raise here would have cost.
      assert log =~ "placement undo did not fully undo"
      assert log =~ "the story is ESCALATED"
      refute log =~ "COULD NOT ESCALATE"

      row = Stages.get(runner.tenant_id, story.id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "release of that claim ALSO failed"

      # And the story still names its dispatch, because the clear is what would have removed
      # it — so the remedy still has its handle, exactly as on the failed-revoke path.
      held = reload(runner.tenant_id, story.id)
      session = session_dispatch(runner.tenant_id, story.id)
      assert held.implementer_dispatch_id == session.id
    end

    # 846.8 AC-1. THE COVERING PROPERTY, not the call order. `undo_claim/5` used to clear
    # `implementer_dispatch_id` and THEN revoke, so a clear that succeeded ahead of a revoke
    # that failed erased the only handle the other remediation path has: the operator holds a
    # story id, `force_unclaim_story/3` reads `story.implementer_dispatch_id` to find the
    # credential, and the story named nothing. The two remediation paths could not cover each
    # other in the one case where covering matters — story d9975b31, four hours, 2026-09-15.
    #
    # So this asserts the RECOVERY, not the ordering: a test that pinned "revoke is called
    # before clear" would pin the mechanism and go green on any refactor that kept the order
    # and dropped the condition, which is the half that actually does the covering.
    test "a revoke the undo could not do leaves force_unclaim able to finish it", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      # Staged BEFORE the placement, because the session dispatch does not exist until
      # `place/4` mints it — which is why the trigger is scoped to the tenant and to the
      # revoke's own column transition rather than to an id.
      name = fail_the_revoke!(runner.tenant_id)
      disconnect(channel, runner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Claims, is refused by the absent runner, then compensates. The caller still gets
          # its own refusal — a revoke that RAISES used to replace it with a Postgrex error
          # and skip both steps after it, `park_unreleased_claim/6` included.
          assert {:error, :runner_not_connected} = place(ctx, dispatch_payload(story))
        end)

      assert log =~ "placement could not revoke the session dispatch"
      assert log =~ "placement undo did not fully undo"

      # THE RESIDUE, and it is the recoverable shape: a credential still live, and a story
      # that still NAMES it. Either half missing and the remedy below has nothing to work
      # from — the id is the whole handle.
      held = session_dispatch(runner.tenant_id, story.id)
      refute held.revoked_at
      released = reload(runner.tenant_id, story.id)
      assert released.implementer_dispatch_id == held.id

      # THE REMEDY. An operator holding only the story id force-unclaims, and that revokes
      # the credential the placement could not — which is what frees the agent's
      # `api_keys_one_role_per_agent_idx` slot and lets the loop place onto it again.
      drop_the_revoke_trigger!(name)

      assert {:ok, _} =
               Progress.force_unclaim_story(runner.tenant_id, story.id, actor_label: "operator")

      recovered = session_dispatch(runner.tenant_id, story.id)
      assert recovered.revoked_at

      # The KEY, not only the dispatch row: the slot is held by `api_keys`, so a dispatch
      # marked revoked with a live key would read as recovered and still refuse every later
      # placement onto this agent for the whole TTL.
      assert AdminRepo.get!(ApiKey, recovered.api_key_id).revoked_at

      # AND THE STORY STILL NAMES THE DISPATCH. The remedy revokes the credential and does
      # NOT clear `implementer_dispatch_id`, deliberately — clearing it there would drop real
      # provenance on every OTHER story that reaches the same call, since force-unclaim cannot
      # tell this residue from a story genuinely implemented under its dispatch (see the
      # comment on `Progress.revoke_released_session_credential/3`). Asserted rather than left
      # implied: the surrounding comments call this call the remediation path, and a reader
      # would otherwise take it for a total one. What clears the column is the next claim
      # THROUGH a dispatch, which `place/4` makes on its own.
      assert reload(runner.tenant_id, story.id).implementer_dispatch_id ==
               held.id
    end
  end

  describe "delete_audit_chain_rows!/1 — what makes the committed-runner sweep possible" do
    test "deletes immutable entries, and leaves the connection's triggers ON", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, _placed} = place(ctx, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout
      assert claimed_entry(runner.tenant_id, story.id)

      raw_id = Ecto.UUID.dump!(runner.tenant_id)

      # This process holds ONE AdminRepo connection for the whole test (`setup`), so both
      # assertions read the SAME connection the delete ran on. Reading the setting from a
      # second checkout proves nothing: the pool would hand back a different connection and
      # report `origin` whether or not the first one leaked, which is precisely what makes this
      # hazard nondeterministic in production use — `bin/mutate.sh` came back exit 1 on the
      # two-checkout version.
      delete_audit_chain_rows!([raw_id])

      # 1. It deletes. Without the suppression `audit_chain_prevent_delete_trigger` raises
      #    and every committed test tenant becomes permanently undeletable.
      assert chain_entry_count(runner.tenant_id) == 0

      # 2. It does not LEAK. `SET LOCAL` reverts with the transaction; a bare `SET` leaves
      #    THIS connection in `replica` when it goes back to the pool, so the next test runs
      #    with user triggers and FK enforcement off — the audit chain's own protection
      #    included — and nothing says so.
      assert replication_role() == "origin"
    end
  end

  # MAKES THE RELEASE FAIL THE ONE WAY PRODUCTION DID, which nothing in Elixir can stage.
  # `Progress.force_unclaim_story/3` writes the release and the stage row in ONE `AdminRepo`
  # transaction and rescues its only post-commit step, so every failure mode reachable from a
  # mock breaks the CLAIM first — and a story with no claim needs no compensation. What the
  # incident actually was is the `:stage` step failing with the `:story` write rolling back
  # WITH it: claim intact, `release_claim/5` reporting `{:error, _}` out of its rescue. A
  # `BEFORE UPDATE` trigger produces exactly that, and is why this module is `async: false` on
  # committed rows (see the moduledoc).
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

    {:ok, _} =
      AdminRepo.transaction(fn ->
        # `SET LOCAL`, never a bare `SET`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock, so
        # this fails fast instead of hanging the run, and the setting reverts with the
        # transaction rather than riding a pooled connection into the next test. It is safe
        # HERE and not on the DROP — see `drop_the_release_trigger!/1` for the asymmetry.
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

    on_exit(fn -> drop_the_release_trigger!(name) end)

    :ok
  end

  # DROPPED EXPLICITLY, because nothing else will. The rows here are committed, so there is no
  # sandbox rollback to undo the DDL — a leaked trigger would fail every later release of a
  # story that happened to reuse this id, and the function would outlive the database's
  # tenants. `IF EXISTS` so a failure before the trigger was created still cleans up.
  #
  # AND DELIBERATELY UNGUARDED WHERE THE CREATE IS GUARDED, because the two are not symmetric.
  # A `lock_timeout` on the CREATE aborts a transaction that created nothing: a clean failure
  # with no residue. On the DROP it aborts with BOTH objects still in the database, which IS
  # the leak — so for any contention between the timeout and ExUnit's on-exit kill (60s, the
  # default `test/test_helper.exs` leaves in place), a guard converts a slow success into a
  # guaranteed leak. A second session holding a sandbox transaction that touched `story_stages`
  # is routine on this box and sits squarely in that window. Unguarded, the DROP waits and then
  # succeeds; only past 60s do the objects leak either way, and all a guard buys there is a
  # named error instead of a killed callback.
  #
  # NO TRANSACTION EITHER, now that no `SET LOCAL` needs one — and that is an improvement, not
  # a leftover: wrapped, a failure on the second statement rolls the first one back and leaves
  # the TRIGGER, the object that does the damage. Run sequentially, the trigger goes first and
  # a failed `DROP FUNCTION` leaves an orphan nothing fires.
  defp drop_the_release_trigger!(name) do
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
    AdminRepo.query!("DROP TRIGGER IF EXISTS #{name}_t ON story_stages")
    AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")

    :ok
  end

  # MAKES THE CLEAR RAISE. Same DDL technique and same reason as `fail_the_release!/1`:
  # `Progress.clear_unused_implementer_dispatch/3` is one `update_all` on an unguarded pool,
  # and nothing reachable from Elixir makes it fail.
  #
  # SCOPED TO THE CLEAR'S OWN COLUMN TRANSITION — `implementer_dispatch_id` going from
  # non-NULL to NULL on this story — so it cannot fire on the release, which writes
  # `agent_status` and `assigned_agent_id` and leaves that column alone. Dropped on exit; a
  # leaked trigger would break every later clear of a story reusing this id.
  defp fail_the_clear!(story_id) do
    name = "placement_clear_fails_#{System.unique_integer([:positive])}"

    {:ok, _} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL lock_timeout = '5s'")

        AdminRepo.query!(
          "CREATE FUNCTION #{name}() RETURNS trigger AS $fn$ BEGIN " <>
            "RAISE EXCEPTION 'placement test: this story cannot drop its dispatch'; " <>
            "END; $fn$ LANGUAGE plpgsql"
        )

        AdminRepo.query!(
          "CREATE TRIGGER #{name}_t BEFORE UPDATE ON stories FOR EACH ROW " <>
            "WHEN (NEW.id = '#{story_id}'::uuid " <>
            "AND OLD.implementer_dispatch_id IS NOT NULL " <>
            "AND NEW.implementer_dispatch_id IS NULL) " <>
            "EXECUTE FUNCTION #{name}()"
        )
      end)

    on_exit(fn -> drop_the_clear_trigger!(name) end)

    :ok
  end

  # Unguarded and untransactioned for the reasons `drop_the_release_trigger!/1` states.
  defp drop_the_clear_trigger!(name) do
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
    AdminRepo.query!("DROP TRIGGER IF EXISTS #{name}_t ON stories")
    AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")

    :ok
  end

  # MAKES THE REVOKE FAIL, the same way and for the same reason `fail_the_release!/1` makes
  # the release fail: nothing reachable from Elixir can. `Dispatches.revoke/3` runs an
  # `AdminRepo` Multi over rows this test's own placement just committed, so a mock would have
  # to replace the module, and `undo_claim/5` resolves it at compile time.
  #
  # SCOPED TO THE REVOKE'S OWN TRANSITION — `revoked_at` going from NULL to non-NULL — and to
  # this tenant, so it names the two revokes of the undo path (the release's post-commit one
  # and `revoke_session_dispatch/3`'s) and nothing the setup or the claim writes. Both are
  # wanted: the release rescues its own and reports success, which is exactly the state the
  # undo then has to handle.
  #
  # Returns the trigger NAME so the test can drop it mid-run — the remedy it then asserts is
  # itself a revoke, and a trigger still installed would break the recovery it is measuring.
  defp fail_the_revoke!(tenant_id) do
    name = "placement_revoke_fails_#{System.unique_integer([:positive])}"

    {:ok, _} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL lock_timeout = '5s'")

        AdminRepo.query!(
          "CREATE FUNCTION #{name}() RETURNS trigger AS $fn$ BEGIN " <>
            "RAISE EXCEPTION 'placement test: this dispatch cannot be revoked'; " <>
            "END; $fn$ LANGUAGE plpgsql"
        )

        AdminRepo.query!(
          "CREATE TRIGGER #{name}_t BEFORE UPDATE ON dispatches FOR EACH ROW " <>
            "WHEN (NEW.tenant_id = '#{tenant_id}'::uuid " <>
            "AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL) " <>
            "EXECUTE FUNCTION #{name}()"
        )
      end)

    on_exit(fn -> drop_the_revoke_trigger!(name) end)

    name
  end

  # `IF EXISTS` on both, so the mid-test drop and the `on_exit` one compose. Unguarded and
  # untransactioned for the reasons `drop_the_release_trigger!/1` states at length.
  defp drop_the_revoke_trigger!(name) do
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
    AdminRepo.query!("DROP TRIGGER IF EXISTS #{name}_t ON dispatches")
    AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")

    :ok
  end

  defp place(ctx, payload, opts \\ []) do
    %{runner: runner, operator: operator} = ctx
    opts = Keyword.merge([api_key: operator], opts)
    Placement.place(runner.tenant_id, runner.id, payload, opts)
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

  # NO `story` KEY: loopctl builds the object itself now (`attach_story/6`), and `place/4`
  # REFUSES a caller-supplied one — a caller able to hand a runner prose is able to run
  # anything on that machine. What the runner receives is asserted in "the dispatch carries
  # the story object loopctl built" rather than echoed from here.
  # NO `branch`, which is the shape an operator sends now that loopctl derives one from the
  # target runner's declaration (story 846.2) and the endpoint documents OMIT THIS. The
  # fixture names a branch of its own; since round 2 that branch is REFUSED
  # `branch_not_unique`, because a caller-supplied name must still carry the story's own
  # suffix or two stories on one repository could share one. Tests that are ABOUT a
  # caller-supplied branch put one back explicitly.
  defp dispatch_payload(story) do
    :runner_dispatch |> build(%{"story_id" => story.id}) |> Map.delete("branch")
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
