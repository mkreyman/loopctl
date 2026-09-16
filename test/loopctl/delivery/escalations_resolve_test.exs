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

    test "a REFUSED resolve still names the CALLER on the revocation it already caused", ctx do
      # #862 review round 2, finding 3. `prepare_story/6` releases the claim, and since #862
      # `force_unclaim_story/3` revokes the story's session dispatch on its way past — so the
      # release is an audit-chain writer, and `Progress` reads its actor as
      # `Keyword.get(opts, :actor_lineage, [])`. `resolve/3` was passing only `actor_label:`
      # down while holding the caller's server-resolved lineage, so that entry was written
      # with an EMPTY actor — the shape the tenant's own operator key writes.
      #
      # THE REFUSED PATH IS WHERE THIS IS OBSERVABLE, and that is a fact about the gate rather
      # than a convenience. `:human_resolution` is a human-only edge and `Stages.human?/1`
      # (`lib/loopctl/delivery/stages.ex:1073-1076`) requires `actor_lineage == []`, so a
      # SUCCESSFUL resolve is by construction one whose lineage is empty and the forwarding
      # changes nothing there. A LINEAGED caller — a session claiming to be a person, exactly
      # what that gate exists to refuse — is refused at `Stages.advance/4`, which runs AFTER
      # `prepare_story/6` has already released the claim and revoked the credential. So the
      # chain gets an entry for a revocation a session caused, and whose name is on it is what
      # this forwarding decides.
      %{tenant: tenant} = ctx
      session = session_dispatch_for(ctx)
      lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      assert {:error, :human_required} = resolve(ctx, :queued, actor_lineage: lineage)

      assert unboxed(fn -> AdminRepo.get!(Dispatch, session.id) end).revoked_at,
             "the release runs before the human gate, so the credential is already revoked"

      assert [entry] = unboxed(fn -> revoked_entries(tenant.id, session.id) end)
      assert entry.actor_lineage == lineage

      refute entry.actor_lineage == [],
             "an empty actor lineage reads as the tenant operator having done this"
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
  defp claimable(ctx), do: unboxed(fn -> Placement.claimable(ctx.tenant.id, ctx.story.id) end)

  defp reload(ctx), do: unboxed(fn -> AdminRepo.get!(Story, ctx.story.id) end)

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end
end
