defmodule Loopctl.Agents.VerifyFlowTest do
  @moduledoc """
  US-48.18: `verify@1` end to end — `Loopctl.Agents.VerifierPlacement` mints and binds the
  verifier dispatch B and pushes the `verify` dispatch, `Loopctl.Agents.AgentResult` records the
  verdict on B's ledger row and enqueues its job, and `Loopctl.Agents.VerifyVerdict` applies it.

  The push and the runner selection are the placement's injected inputs (`:dispatch`,
  `:runners`), so no socket is needed; everything custody-bearing — the operator key, the mint,
  the bind, report, review, verify, the stage effect, the revoke — runs for real.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.AgentResult
  alias Loopctl.Agents.VerifierPlacement
  alias Loopctl.Agents.VerifyVerdict
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.ImplementerStart
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.VerifyVerdictWorker

  setup :verify_on_exit!

  @budgets %{wall_clock_seconds: 1_200, max_turns: 40}
  @other_head String.duplicate("b", 40)

  setup do
    fixture(:verify_ready_story, %{})
  end

  # Places with `runners` as the selectable set and a push that records what it was sent.
  defp place(ctx, runners) do
    test_pid = self()

    VerifierPlacement.place(ctx.tenant.id, ctx.story.id, @budgets,
      api_key: ctx.operator_key,
      runners: fn _repo -> runners end,
      dispatch: fn tenant_id, runner_id, payload ->
        send(test_pid, {:pushed, tenant_id, runner_id, payload})
        :ok
      end,
      actor_label: "test:verify_dispatcher"
    )
  end

  defp placed!(ctx) do
    assert {:ok, :dispatched} = place(ctx, [ctx.implementer_runner, ctx.verifier_runner])
    assert_received {:pushed, _tenant_id, runner_id, payload}
    assert runner_id == ctx.verifier_runner.id
    payload
  end

  # The runner's answer, recorded the way the channel records it: B's ledger row (written by
  # `Runners.dispatch/3` in production; the push here is injected, so the fixture writes it)
  # and `AgentResult.apply/4`, as `runner`. Oban is manual so the job is not run on insert;
  # returns the job's args.
  defp answer(ctx, payload, attrs, runner \\ nil) do
    runner = runner || ctx.verifier_runner

    fixture(:accepted_dispatch, %{
      tenant_id: ctx.tenant.id,
      runner: runner,
      dispatch_id: payload["dispatch_id"],
      story_id: ctx.story.id,
      claim_epoch: 1,
      kind: "verify"
    })

    message = %{
      dispatch_id: payload["dispatch_id"],
      claim_epoch: 1,
      spec: %{id: "verify", version: 1},
      result: Map.merge(%{"verdict" => "pass", "head_sha" => ctx.head, "findings" => []}, attrs)
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{replayed?: false}} = AgentResult.apply(ctx.tenant.id, runner.id, message)
    end)

    %{
      "tenant_id" => ctx.tenant.id,
      "story_id" => ctx.story.id,
      "dispatch_id" => payload["dispatch_id"]
    }
  end

  defp story(ctx), do: AdminRepo.get!(Story, ctx.story.id)
  defp stage(ctx), do: Stages.get(ctx.tenant.id, ctx.story.id)
  defp dispatch(id), do: AdminRepo.get!(Dispatch, id)

  defp audit_actions(ctx) do
    AdminRepo.all(
      from a in AuditLog,
        where: a.tenant_id == ^ctx.tenant.id and a.entity_id == ^ctx.story.id,
        select: a.action
    )
  end

  describe "placement (AC-48.18.2)" do
    test "mints B as a new root for the OTHER runner's agent, binds it, and pushes a verify " <>
           "dispatch whose id is B's and which carries no credential",
         ctx do
      payload = placed!(ctx)
      b = dispatch(payload["dispatch_id"])

      assert b.parent_dispatch_id == nil
      assert b.lineage_path == [b.id]
      assert b.role == :orchestrator
      assert b.agent_id == ctx.verifier_runner.agent_id
      refute b.agent_id == ctx.story.assigned_agent_id
      assert b.story_id == ctx.story.id
      assert is_nil(b.revoked_at)

      assert story(ctx).verifier_dispatch_id == b.id

      assert payload["kind"] == "verify"
      assert payload["branch"] == "loop/us-1"
      assert payload["verify"] == %{"pr_number" => 77, "head_sha" => ctx.head}
      assert payload["story"]["id"] == ctx.story.id
      assert payload["claim_epoch"] == 1

      assert Enum.sort(Map.keys(payload)) ==
               Enum.sort(~w(dispatch_id story_id kind repo branch base_branch claim_epoch
                            wall_clock_seconds max_turns story verify))

      assert {:ok, _} = RunnerContract.cast_dispatch(payload)
    end

    test "a refused push revokes B", ctx do
      assert {:error, :runner_not_connected} =
               VerifierPlacement.place(ctx.tenant.id, ctx.story.id, @budgets,
                 api_key: ctx.operator_key,
                 runners: fn _repo -> [ctx.verifier_runner] end,
                 dispatch: fn _t, _r, _p -> {:error, :runner_not_connected} end,
                 actor_label: "test"
               )

      b = dispatch(story(ctx).verifier_dispatch_id)
      refute is_nil(b.revoked_at)
    end

    test "a key a dispatch minted is not an operator key", ctx do
      {:ok, %{dispatch: minted}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :user,
          agent_id: fixture(:agent, %{tenant_id: ctx.tenant.id}).id
        })

      key = AdminRepo.get!(ApiKey, minted.api_key_id)

      assert {:error, :no_operator_key} =
               VerifierPlacement.place(ctx.tenant.id, ctx.story.id, @budgets,
                 api_key: key,
                 runners: fn _repo -> [ctx.verifier_runner] end,
                 dispatch: fn _t, _r, _p -> flunk("pushed") end,
                 actor_label: "test"
               )

      assert story(ctx).verifier_dispatch_id == nil
    end

    test "an agent-rooted tenant is refused before anything is minted" do
      ctx = fixture(:verify_ready_story, %{trust_tier: :agent_rooted})

      assert {:error, :custody_tier_required} = place(ctx, [ctx.verifier_runner])
      refute_received {:pushed, _, _, _}
      assert story(ctx).verifier_dispatch_id == nil
    end
  end

  describe "TC-48.18.3: one runner cannot verify its own work" do
    test "only the implementer's runner, and no other agent in the tenant: escalated, " <>
           "nothing placed",
         ctx do
      {1, _} =
        from(r in Runner, where: r.id == ^ctx.verifier_runner.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      assert {:ok, :escalated} = place(ctx, [ctx.implementer_runner])
      refute_received {:pushed, _, _, _}

      row = stage(ctx)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "no_independent_verifier_runner"

      assert AdminRepo.all(from d in Dispatch, where: d.story_id == ^ctx.story.id, select: d.id) ==
               [ctx.implementer.id]

      assert story(ctx).verifier_dispatch_id == nil
    end

    test "another agent's runner exists but is busy: no runner now, no escalation", ctx do
      assert {:error, :no_runner} = place(ctx, [ctx.implementer_runner])
      refute_received {:pushed, _, _, _}
      assert stage(ctx).stage == :ci
    end

    test "nothing selectable at all is no runner, never an escalation", ctx do
      {1, _} =
        from(r in Runner, where: r.id == ^ctx.verifier_runner.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      assert {:error, :no_runner} = place(ctx, [])
      assert stage(ctx).stage == :ci
    end
  end

  describe "TC-48.18.1: a pass verdict leaves merge_custody_status :ok at the current head" do
    test "reports, reviews and verifies as B, records the head, and revokes B", ctx do
      payload = placed!(ctx)
      b = dispatch(payload["dispatch_id"])

      assert {:ok, :verified} = VerifyVerdict.apply(answer(ctx, payload, %{}))

      story = story(ctx)
      assert story.verifier_dispatch_id == b.id
      assert story.verified_status == :verified
      assert story.agent_status == :reported_done
      assert stage(ctx).verified_head_sha == ctx.head
      assert Progress.merge_custody_status(story) == :ok
      refute is_nil(dispatch(b.id).revoked_at)

      # The review is B's, of this report.
      assert [%ReviewRecord{reviewer_agent_id: reviewer, reviewed_report_at: at}] =
               AdminRepo.all(from r in ReviewRecord, where: r.story_id == ^story.id)

      assert reviewer == b.agent_id
      assert at == story.reported_done_at
    end

    test "a retried job resumes rather than repeating, and a finished one does nothing", ctx do
      payload = placed!(ctx)
      b = dispatch(payload["dispatch_id"])

      # The first attempt got as far as the report, then died.
      assert {:ok, :started} =
               ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)

      assert {:ok, _} =
               Progress.report_story(ctx.tenant.id, ctx.story.id,
                 agent_id: b.agent_id,
                 reporter_lineage: b.lineage_path
               )

      args = answer(ctx, payload, %{})
      assert {:ok, :verified} = VerifyVerdict.apply(args)
      assert {:ok, :verified} = VerifyVerdict.apply(args)

      assert AdminRepo.aggregate(
               from(r in ReviewRecord, where: r.story_id == ^ctx.story.id),
               :count
             ) ==
               1

      assert story(ctx).verified_status == :verified
    end

    test "the verdict's job is enqueued after the ledger commits, once, carrying ids only",
         ctx do
      payload = placed!(ctx)

      record =
        fixture(:accepted_dispatch, %{
          tenant_id: ctx.tenant.id,
          runner: ctx.verifier_runner,
          dispatch_id: payload["dispatch_id"],
          story_id: ctx.story.id,
          claim_epoch: 1,
          kind: "verify"
        })

      message = %{
        dispatch_id: record.dispatch_id,
        claim_epoch: 1,
        spec: %{id: "verify", version: 1},
        result: %{"verdict" => "pass", "head_sha" => ctx.head, "findings" => []}
      }

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{replayed?: false}} =
                 AgentResult.apply(ctx.tenant.id, ctx.verifier_runner.id, message)

        assert {:ok, %{replayed?: true}} =
                 AgentResult.apply(ctx.tenant.id, ctx.verifier_runner.id, message)

        assert [job] = all_enqueued(worker: VerifyVerdictWorker)

        assert job.args == %{
                 "tenant_id" => ctx.tenant.id,
                 "story_id" => ctx.story.id,
                 "dispatch_id" => payload["dispatch_id"]
               }

        # Nothing custody-bearing moved with the ledger write.
        assert story(ctx).verified_status == :unverified

        assert :ok = perform_job(VerifyVerdictWorker, job.args)
        assert story(ctx).verified_status == :verified
      end)
    end

    test "a verdict whose job was never inserted is enqueued by the sweep, and only until " <>
           "it is applied",
         ctx do
      payload = placed!(ctx)

      record =
        fixture(:accepted_dispatch, %{
          tenant_id: ctx.tenant.id,
          runner: ctx.verifier_runner,
          dispatch_id: payload["dispatch_id"],
          story_id: ctx.story.id,
          claim_epoch: 1,
          kind: "verify"
        })

      result = %{"verdict" => "pass", "head_sha" => ctx.head, "findings" => []}

      # The ledger commit WITHOUT the insert that follows it: the node died in between.
      {:ok, %{spec: spec, result: validated}} =
        AgentResult.admit(%{spec: %{id: "verify", version: 1}, result: result})

      assert {:ok, {:recorded, _}} =
               DispatchLedger.record_agent_result(
                 ctx.tenant.id,
                 ctx.verifier_runner.id,
                 %{dispatch_id: record.dispatch_id, claim_epoch: 1},
                 %{
                   kind: spec.kind,
                   spec: "verify@1",
                   result: validated,
                   digest: String.duplicate("d", 64)
                 }
               )

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert [] = all_enqueued(worker: VerifyVerdictWorker)
        assert VerifyVerdict.enqueue_unapplied(20) == 1
        assert [job] = all_enqueued(worker: VerifyVerdictWorker)
        assert job.args["dispatch_id"] == payload["dispatch_id"]

        assert :ok = perform_job(VerifyVerdictWorker, job.args)
        assert story(ctx).verified_status == :verified

        # Applied: B is revoked, so the sweep no longer names it.
        assert VerifyVerdict.enqueue_unapplied(20) == 0
      end)
    end
  end

  describe "a custody halt freezes the verdict and the start" do
    test "a pass verdict on a halted tenant snoozes, moves nothing, and applies once cleared",
         ctx do
      payload = placed!(ctx)
      args = answer(ctx, payload, %{})
      halt!(ctx, DateTime.utc_now())

      assert {:snooze, seconds} = VerifyVerdict.apply(args)
      assert seconds > 0

      story = story(ctx)
      assert story.verified_status != :verified
      assert story.agent_status == :assigned
      assert is_nil(stage(ctx).verified_head_sha)
      assert is_nil(dispatch(payload["dispatch_id"]).revoked_at)

      halt!(ctx, nil)
      assert {:ok, :verified} = VerifyVerdict.apply(args)
      assert story(ctx).verified_status == :verified
    end

    test "the worker hands a halt's snooze to Oban rather than failing an attempt", ctx do
      payload = placed!(ctx)
      args = answer(ctx, payload, %{})
      halt!(ctx, DateTime.utc_now())

      assert {:snooze, _} = perform_job(VerifyVerdictWorker, args)
    end

    test "ImplementerStart starts nothing on a halted tenant", ctx do
      halt!(ctx, DateTime.utc_now())

      assert {:error, :tenant_halted} =
               ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)

      assert story(ctx).agent_status == :assigned
    end
  end

  # `update_all`, not a changeset on `ctx.tenant`: that struct still reads nil after a halt, so
  # clearing it through `change/2` would record no change and leave the tenant halted.
  defp halt!(ctx, at) do
    {1, _} =
      AdminRepo.update_all(from(t in Loopctl.Tenants.Tenant, where: t.id == ^ctx.tenant.id),
        set: [custody_halted_at: at]
      )
  end

  describe "TC-48.18.2: a verdict for a moved head is dropped" do
    test "a pass naming head X while the row's head is Y changes nothing and is recorded", ctx do
      payload = placed!(ctx)
      b = dispatch(payload["dispatch_id"])

      assert {:ok, :dropped} =
               VerifyVerdict.apply(answer(ctx, payload, %{"head_sha" => @other_head}))

      story = story(ctx)
      assert story.verified_status == :unverified
      assert story.agent_status == :assigned
      assert stage(ctx).verified_head_sha == nil
      assert "verify_verdict_dropped" in audit_actions(ctx)
      refute is_nil(dispatch(b.id).revoked_at)
    end

    test "a story no longer at ci is dropped", ctx do
      payload = placed!(ctx)

      {1, _} =
        from(s in StoryStage, where: s.story_id == ^ctx.story.id)
        |> AdminRepo.update_all(set: [stage: :implementing])

      assert {:ok, :dropped} = VerifyVerdict.apply(answer(ctx, payload, %{}))
      assert story(ctx).verified_status == :unverified
    end

    test "a verdict from the implementer's runner is not B's and is dropped", ctx do
      payload = placed!(ctx)

      assert {:ok, :dropped} =
               VerifyVerdict.apply(answer(ctx, payload, %{}, ctx.implementer_runner))

      assert story(ctx).verified_status == :unverified
      assert story(ctx).agent_status == :assigned
    end

    test "a job naming a dispatch with no recorded verify verdict is cancelled", ctx do
      payload = placed!(ctx)
      args = answer(ctx, payload, %{})

      assert {:cancel, :no_recorded_verdict} =
               VerifyVerdict.apply(%{args | "dispatch_id" => ctx.implementer.id})

      assert story(ctx).verified_status == :unverified
      # The implementer's dispatch is not a verifier dispatch: the drop does not revoke it.
      assert is_nil(dispatch(ctx.implementer.id).revoked_at)
    end

    test "a job naming another story than the verdict's ledger row is cancelled", ctx do
      payload = placed!(ctx)
      args = answer(ctx, payload, %{})
      other = fixture(:story, %{tenant_id: ctx.tenant.id})

      assert {:cancel, :no_recorded_verdict} =
               VerifyVerdict.apply(%{args | "story_id" => other.id})

      assert story(ctx).verified_status == :unverified
    end

    test "a head that moves after verify retires the verification it made", ctx do
      payload = placed!(ctx)
      assert {:ok, :verified} = VerifyVerdict.apply(answer(ctx, payload, %{}))

      # The row as `apply/1` read it, judging a head the row no longer has.
      read = %{stage(ctx) | head_sha: @other_head}

      {1, _} =
        from(s in StoryStage, where: s.story_id == ^ctx.story.id)
        |> AdminRepo.update_all(set: [verified_head_sha: nil])

      assert {:error, {:verified_head_not_recorded, :verdict_stale}} =
               VerifyVerdict.record_verified_head(
                 ctx.tenant.id,
                 ctx.story.id,
                 read,
                 payload["dispatch_id"]
               )

      assert stage(ctx).verified_head_sha == nil
      assert story(ctx).verified_status == :unverified
      assert story(ctx).agent_status == :implementing
    end
  end

  describe "reject" do
    test "sends the story back to work over :verify_rejected with the findings, revokes B",
         ctx do
      payload = placed!(ctx)
      b = dispatch(payload["dispatch_id"])

      findings = ["AC-2 is not met: no test covers the empty list", "the migration has no down"]

      assert {:ok, :rejected} =
               VerifyVerdict.apply(
                 answer(ctx, payload, %{"verdict" => "reject", "findings" => findings})
               )

      row = stage(ctx)
      assert row.stage == :implementing
      assert row.head_sha == nil
      assert row.verified_head_sha == nil

      assert [event] =
               AdminRepo.all(
                 from e in StageEvent,
                   where: e.story_id == ^ctx.story.id and e.edge == "verify_rejected"
               )

      assert inspect(event.data) =~ "no test covers the empty list"
      assert story(ctx).verified_status == :unverified
      refute is_nil(dispatch(b.id).revoked_at)
    end
  end

  describe "tenant isolation" do
    test "a verdict naming another tenant's story moves nothing in either tenant", ctx do
      payload = placed!(ctx)
      other = fixture(:verify_ready_story, %{})

      args = answer(ctx, payload, %{})

      assert {:cancel, :no_recorded_verdict} =
               VerifyVerdict.apply(%{args | "tenant_id" => other.tenant.id})

      assert story(ctx).verified_status == :unverified
      assert AdminRepo.get!(Story, other.story.id).verified_status == :unverified
    end

    test "placement never reads another tenant's runner as independent", ctx do
      other = fixture(:verify_ready_story, %{})

      {1, _} =
        from(r in Runner, where: r.id == ^ctx.verifier_runner.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      # The other tenant's live verifier runner does not stop this tenant's escalation.
      assert is_nil(AdminRepo.get!(Runner, other.verifier_runner.id).revoked_at)
      assert {:ok, :escalated} = place(ctx, [ctx.implementer_runner])
    end
  end
end
