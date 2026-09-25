defmodule Loopctl.Delivery.EscalationsResolveTest do
  @moduledoc """
  `Escalations.resolve/3` — the human half of the escalation pair (#803 design §8, #851).

  Its own file, `async: false` and COMMITTED, because resolving a story to `queued` crosses
  BOTH repos: the stage transition runs on the RLS `Loopctl.Repo` while the claim release and
  the re-contract run on `AdminRepo`. Two sandbox connections in one process cannot see each
  other's uncommitted rows, and worse, the release's row lock is held for the rest of the test
  — so a sandboxed version of this test times the transition out on a lock rather than
  exercising it. Everything here is committed and run unboxed;
  `sweep_committed_runner_tenants/0` removes it.

  The property under test is the one a stage row alone cannot state: **a story sent back to
  `queued` must be PLACEABLE**, which means its `agent_status` as well as its stage.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Queries
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 5

  setup do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {_raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    story = fixture(:committed_story, %{tenant_id: tenant.id})

    unboxed(fn ->
      {1, _} =
        AdminRepo.update_all(
          from(s in Story, where: s.id == ^story.id),
          set: [
            assigned_agent_id: runner.agent_id,
            agent_status: :implementing,
            claim_epoch: @epoch
          ]
        )

      fixture(:story_stage, %{
        repo: AdminRepo,
        tenant_id: tenant.id,
        story_id: story.id,
        stage: :escalated,
        claim_epoch: @epoch,
        escalation_reason: "the session asked for a human"
      })
    end)

    %{tenant: tenant, story: story, runner: runner}
  end

  describe "resolve/3 to :queued" do
    test "the story is placeable afterwards, not just re-staged", ctx do
      assert {:ok, row} = resolve(ctx, :queued)
      assert row.stage == :queued

      # THE HALF A STAGE ROW CANNOT SAY. Escalating does not release the claim, so the story
      # was still assigned to the stopped session at `:implementing` while its row said
      # `queued` — and `Placement.claimable/2` wants `contracted` AND `queued`, so no placement
      # would take a story an operator had deliberately re-queued. Nothing healed it either:
      # the lease's release leaves `:pending`, which is not `:contracted`.
      story = reload(ctx)
      assert story.agent_status == :contracted
      assert story.assigned_agent_id == nil

      # Asserted through the FUNCTION a placement calls, not by restating its rule: this is
      # what "placeable" means, and a test that listed the conditions itself would pass a
      # story `place/4` still refused.
      assert :ok = claimable(ctx)
    end

    # #883 review round 3, finding 2. The transition commits before the re-contract runs, so a
    # re-contract that raised or was refused left `queued` + `pending`: no placement takes it,
    # and a plain retry was answered `{:not_escalated, :queued}`. Resolving again finishes it.
    test "a re-queue whose re-contract never landed is finished by resolving again", ctx do
      assert {:ok, _row} = resolve(ctx, :queued)
      unstick(ctx)
      assert {:error, :invalid_transition} = claimable(ctx)

      assert {:ok, row} = resolve(ctx, :queued)
      assert row.stage == :queued
      assert reload(ctx).agent_status == :contracted
      assert :ok = claimable(ctx)
    end

    test "finishing a re-queue still asks the human gate first", ctx do
      assert {:ok, _row} = resolve(ctx, :queued)
      unstick(ctx)

      assert {:error, :human_required} =
               resolve(ctx, :queued, actor_lineage: [Ecto.UUID.generate()])

      assert reload(ctx).agent_status == :pending
    end

    test "a resolved story is CLAIMABLE: the claim's held-stage refusal lets it go", ctx do
      # While the row sits at `escalated` a claim is refused `:story_held` — a human owns the
      # story. Resolution moves the row out first, so the refusal must not outlive it.
      assert {:ok, %{stage: :queued}} = resolve(ctx, :queued)

      agent = unboxed(fn -> fixture(:agent, %{tenant_id: ctx.tenant.id}) end)

      assert {:ok, claimed} =
               unboxed(fn ->
                 Progress.claim_story(ctx.tenant.id, ctx.story.id, agent_id: agent.id)
               end)

      assert claimed.agent_status == :assigned
    end

    test "the row is bound to the epoch the release produced", ctx do
      before = reload(ctx).claim_epoch

      assert {:ok, row} = resolve(ctx, :queued)

      # Releasing a claim BUMPS the story's epoch, so a transition fenced on the epoch read
      # before the release would be refused `:stale_claim_epoch` — and the row would be left
      # behind the story it describes, which is the state every later advance is refused
      # against.
      after_resolve = reload(ctx)
      assert after_resolve.claim_epoch > before
      assert row.claim_epoch == after_resolve.claim_epoch
    end
  end

  describe "resolve/3 to a terminal stage" do
    test "done and failed change no claim, because the story is finished with", ctx do
      assert {:ok, row} = resolve(ctx, :failed)
      assert row.stage == :failed

      # Re-contracting a story nobody is going to work would be inventing work, and releasing
      # a claim it no longer matters who holds buys nothing. The epoch is untouched, which is
      # what says no claim moved.
      story = reload(ctx)
      assert story.claim_epoch == @epoch
      assert story.agent_status == :implementing
    end
  end

  for to <- [:done, :failed] do
    describe "a story resolved to #{to}" do
      test "is never listed, contracted or claimed again once its claim ends", ctx do
        assert {:ok, %{stage: unquote(to)}} = resolve(ctx, unquote(to))

        # The finished session's claim ends the way any claim does — the lease reclaim, or an
        # operator — and leaves the story `pending` with nobody on it: the shape of work.
        unboxed(fn -> {:ok, _} = Progress.force_unclaim_story(ctx.tenant.id, ctx.story.id) end)
        assert reload(ctx).agent_status == :pending

        refute ctx.story.id in ready_ids(ctx)

        assert {:error, :story_held} =
                 unboxed(fn ->
                   Progress.contract_story(ctx.tenant.id, ctx.story.id, %{},
                     skip_contract_check: true
                   )
                 end)

        # A story already `contracted` when it was finished is refused at the claim too.
        unboxed(fn ->
          AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
            set: [agent_status: :contracted]
          )
        end)

        agent = unboxed(fn -> fixture(:agent, %{tenant_id: ctx.tenant.id}) end)

        assert {:error, :story_held} =
                 unboxed(fn ->
                   Progress.claim_story(ctx.tenant.id, ctx.story.id, agent_id: agent.id)
                 end)

        assert reload(ctx).assigned_agent_id == nil
      end
    end
  end

  describe "the human gate" do
    test "an AGENT role is refused by the machine itself, whatever the route allows", ctx do
      # The route's `role: :user` plug is one gate; this is the other, and it is the one that
      # holds if a future route is mounted differently. `Stages.human?/1` wants a `:user`+ role
      # AND an empty lineage — the two halves of "a person", since a dispatch-minted user key
      # carries a lineage.
      assert {:error, :human_required} = resolve(ctx, :queued, actor_role: :agent)
      assert unboxed(fn -> Stages.get(ctx.tenant.id, ctx.story.id) end).stage == :escalated
    end

    test "a LINEAGED caller is refused even at user role", ctx do
      assert {:error, :human_required} =
               resolve(ctx, :queued, actor_lineage: [Ecto.UUID.generate()])

      assert unboxed(fn -> Stages.get(ctx.tenant.id, ctx.story.id) end).stage == :escalated
    end

    test "a REFUSED resolve does not revoke the implementer's session credential", ctx do
      # #862 review round 3, finding 1 — and the direct reversal of what round 2's version of
      # this test asserted. It pinned the destruction: "the release runs before the human gate,
      # so the credential is already revoked". That was an accurate reading of the code and the
      # wrong thing to hold in place.
      #
      # THE REACHABLE SHAPE. A dispatch-minted `:user`-role key is mintable (`@roles` in
      # `Loopctl.Dispatches.Dispatch`) and clears the route's `role: :user` plug, so a SESSION
      # can POST `to: queued` on any escalated story. `prepare_story/6` released the claim,
      # bumped the epoch, revoked the implementer's LIVE session credential and every
      # descendant dispatch, re-contracted the story — and only THEN did `Stages.human?/1`
      # (`lib/loopctl/delivery/stages.ex:1127-1130`, which requires `actor_lineage == []`)
      # refuse the caller. Repeatably, on any escalated story: a refusal that cost the
      # implementing agent its key.
      #
      # SPLIT FROM THE STORY-STATE CASE BELOW ON PURPOSE. ExUnit stops a test at its first
      # failed assertion, so a single test covering both would prove only whichever assertion
      # happens to be written first — and the two cover different writes `prepare_story/6`
      # made. Two tests means the ordering mutation has to turn TWO of them red.
      %{tenant: tenant} = ctx
      session = session_dispatch_for(ctx)
      lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      assert {:error, :human_required} = resolve(ctx, :queued, actor_lineage: lineage)

      refute unboxed(fn -> AdminRepo.get!(Dispatch, session.id) end).revoked_at,
             "a refused resolve must not revoke the implementer's live session credential"

      assert unboxed(fn -> revoked_entries(tenant.id, session.id) end) == [],
             "nothing was revoked, so the immutable chain must carry no revocation entry"
    end

    test "a REFUSED resolve does not release the claim", ctx do
      # The other half of the pre-state. The release is what BUMPS the epoch, clears
      # `assigned_agent_id` and re-contracts the story, and each of those is a write a caller
      # the gate refuses must not be able to cause. The stage row is asserted last because it
      # is the one thing the old ordering left alone — `Stages.advance/4` never ran — so a test
      # that checked only the stage passed the defect this covers.
      %{tenant: tenant} = ctx
      before = reload(ctx)
      lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      assert {:error, :human_required} = resolve(ctx, :queued, actor_lineage: lineage)

      after_refusal = reload(ctx)
      assert after_refusal.claim_epoch == before.claim_epoch, "the claim epoch moved"
      assert after_refusal.assigned_agent_id == before.assigned_agent_id, "the claim was released"
      assert after_refusal.agent_status == before.agent_status, "the story was re-contracted"

      assert unboxed(fn -> Stages.get(tenant.id, ctx.story.id) end).stage == :escalated
    end

    test "a caller that PASSES the gate still gets the release, so the gate did not break it",
         ctx do
      # The positive control for the test above. Without it, "a refused resolve destroys
      # nothing" is satisfied by a `resolve/3` that destroys nothing ever — including on the
      # human path, where releasing the claim and revoking the dead session's credential is
      # exactly what the function is for.
      session = session_dispatch_for(ctx)

      assert {:ok, row} = resolve(ctx, :queued)
      assert row.stage == :queued

      assert unboxed(fn -> AdminRepo.get!(Dispatch, session.id) end).revoked_at,
             "a human resolve to queued must still revoke the released session's credential"

      story = reload(ctx)
      assert story.assigned_agent_id == nil
      assert story.claim_epoch > @epoch
    end
  end

  describe "what may be resolved" do
    test "a story that is not escalated is named, not answered with stale_stage", ctx do
      unboxed(fn ->
        {:ok, _} =
          Stages.advance(ctx.tenant.id, ctx.story.id, {:escalated, :failed, :human_resolution},
            claim_epoch: @epoch,
            actor_role: :user,
            actor_lineage: [],
            actor_label: "test"
          )
      end)

      # `stale_stage` is the machine's word for a story that moved under a runner. Answering it
      # here would send an operator looking for a race that did not happen.
      assert {:error, {:not_escalated, :failed}} = resolve(ctx, :queued)
    end

    test "a target the machine has no edge for is refused before anything is read", ctx do
      assert {:error, {:unresolvable_target, :implementing}} = resolve(ctx, :implementing)
      assert unboxed(fn -> Stages.get(ctx.tenant.id, ctx.story.id) end).stage == :escalated
    end
  end

  defp resolve(ctx, to, opts \\ []) do
    unboxed(fn ->
      Escalations.resolve(ctx.tenant.id, ctx.story.id,
        to: to,
        actor_label: "test:operator",
        actor_role: Keyword.get(opts, :actor_role, :user),
        actor_lineage: Keyword.get(opts, :actor_lineage, [])
      )
    end)
  end

  # A session dispatch minted FOR this story, recorded on it — the shape
  # `Placement.mint_session_dispatch/5` produces, and the only shape
  # `Dispatches.revoke_story_session/4` will revoke.
  defp session_dispatch_for(ctx) do
    unboxed(fn ->
      agent = fixture(:agent, %{tenant_id: ctx.tenant.id})

      {:ok, %{dispatch: root}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{role: :orchestrator}, actor_lineage: [])

      {:ok, %{dispatch: session}} =
        Dispatches.create_dispatch(
          ctx.tenant.id,
          %{
            role: :agent,
            agent_id: agent.id,
            story_id: ctx.story.id,
            parent_dispatch_id: root.id
          },
          actor_lineage: root.lineage_path
        )

      {1, _} =
        AdminRepo.update_all(
          from(s in Story, where: s.id == ^ctx.story.id),
          set: [implementer_dispatch_id: session.id]
        )

      session
    end)
  end

  defp revoked_entries(tenant_id, dispatch_id) do
    AdminRepo.all(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^dispatch_id,
        where: e.action == "dispatch_revoked"
    )
  end

  # ASKED THROUGH THE FUNCTION A PLACEMENT ASKS, never by restating its rule: a test that
  # listed the conditions itself would pass a story `place/4` still refused.
  # The state a re-contract that failed after its transition leaves: the row at `queued`,
  # the story `pending`.
  defp unstick(ctx) do
    unboxed(fn ->
      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
          set: [agent_status: :pending]
        )
    end)
  end

  defp claimable(ctx), do: unboxed(fn -> Placement.claimable(ctx.tenant.id, ctx.story.id) end)

  defp reload(ctx), do: unboxed(fn -> AdminRepo.get!(Story, ctx.story.id) end)

  defp ready_ids(ctx) do
    {:ok, %{data: stories}} =
      unboxed(fn -> Queries.list_ready_stories(ctx.tenant.id, page_size: 500) end)

    Enum.map(stories, & &1.id)
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end
end
