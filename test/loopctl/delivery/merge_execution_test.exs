defmodule Loopctl.Delivery.MergeExecutionTest do
  @moduledoc """
  US-48.17: control decides the pull-request route's merge, the runner executes it.

  - TC-48.17.1 (AC-48.17.2): the merge gate allows, ONE instruction naming the claim's
    dispatch, the pull request and the head is pushed to the runner holding the claim, and the
    runner's `ci -> merged` lands with that merge sha.
  - Every other verdict of the gate, the once-per-head record and its bounds, a refused push.
  - AC-48.17.3: the claim is held open while the runner is live, never past the implement
    dispatch's credential; a runner that is gone escalates the story instead of re-queueing it.
  - Custody: a halted tenant writes nothing, a tenant that is not human-anchored is skipped,
    and another tenant's sweep or job reaches none of these rows.

  The real `MergePrecondition.enforce/3` runs over a stubbed forge (`MockPullRequestSource`);
  the push, the enqueue, runner liveness and the clock are injected. Every row lives on the
  sandbox connection, so the module is async.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Delivery.MergeExecution
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Intake.Source
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.MergeInstructionWorker

  setup :verify_on_exit!

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @merge_sha String.duplicate("c", 40)

  setup do
    fixture(:merge_instruction_story, %{repo: @repo, head_sha: @head})
  end

  describe "TC-48.17.1: an allow leads to one instruction and the runner's merge" do
    test "the sweep enqueues one job, the job pushes one instruction, the report lands", ctx do
      allow_source()
      now = DateTime.utc_now()

      assert [:instruction_enqueued] = sweep(ctx, now)
      assert_received {:enqueued, args}

      assert args == %{
               "tenant_id" => ctx.tenant.id,
               "story_id" => ctx.story_id,
               "head_sha" => @head
             }

      assert {:ok, :pushed} = instruct(args, now)

      # Exactly the contract message, every value control's own.
      assert_received {:instructed, tenant_id, runner_id, payload}
      assert tenant_id == ctx.tenant.id
      assert runner_id == ctx.runner.id

      assert payload == %{
               "dispatch_id" => ctx.dispatch_id,
               "claim_epoch" => 0,
               "story_id" => ctx.story_id,
               "repo" => @repo,
               "pr_number" => 4242,
               "head_sha" => @head,
               "merge_method" => "squash"
             }

      row = Stages.get(ctx.tenant.id, ctx.story_id)
      assert row.merge_gate_allowed_sha == @head

      assert %{"head_sha" => @head, "sends" => 1, "refusals" => 0, "outcome" => "pushed"} =
               row.merge_instruction

      assert row.merge_instruction["dispatch_id"] == ctx.dispatch_id
      assert [%{data: %{"sends" => 1}}] = events(ctx, "merge_instructed")

      # ONE: neither the job nor the next sweep sends a second while it is outstanding.
      assert {:ok, :not_due} = instruct(args, DateTime.add(now, 5))
      refute_received {:instructed, _, _, _}
      assert [:held] = sweep(ctx, DateTime.add(now, 5))
      refute_received {:enqueued, _}

      # The runner merges that head and reports it under the instructed dispatch.
      assert {:ok, merged} =
               RunnerStages.apply(ctx.tenant.id, ctx.runner.id, %{
                 dispatch_id: ctx.dispatch_id,
                 claim_epoch: 0,
                 from: :ci,
                 to: :merged,
                 edge: :forward,
                 effects: %{merge_sha: @merge_sha}
               })

      assert merged.stage == :merged
      assert merged.merge_sha == @merge_sha
      # The allow is for this head, so the report is NOT an ungated merge.
      assert events(ctx, "transitioned") |> Enum.map(& &1.edge) |> Enum.member?("ungated_merge") ==
               false
    end

    test "the worker runs the same job and is unique per story and head", ctx do
      args = %{"tenant_id" => ctx.tenant.id, "story_id" => ctx.story_id, "head_sha" => @head}

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %Oban.Job{conflict?: false}} =
                 args |> MergeInstructionWorker.new() |> Oban.insert()

        assert {:ok, %Oban.Job{conflict?: true}} =
                 args |> MergeInstructionWorker.new() |> Oban.insert()

        other = Map.put(args, "head_sha", String.duplicate("d", 40))

        assert {:ok, %Oban.Job{conflict?: false}} =
                 other |> MergeInstructionWorker.new() |> Oban.insert()
      end)
    end
  end

  describe "the gate's other verdicts" do
    test ":refuse sends nothing; the gate already escalated over merge_gate", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})

      assert {:ok, :refused} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}

      row = Stages.get(ctx.tenant.id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "merge_gate"
      assert is_nil(row.merge_instruction)
    end

    test ":head_moved sends nothing; the gate already sent the story back", ctx do
      stub_source(
        files: ["lib/widgets/thing.ex"],
        diffstat: %{files: 1, changed_lines: 1},
        head: String.duplicate("e", 40)
      )

      assert {:ok, :head_moved} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
      assert Stages.get(ctx.tenant.id, ctx.story_id).stage == :implementing
    end

    test ":unevaluated snoozes and sends nothing", ctx do
      Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _n ->
        {:error, {:github_unreachable, :timeout}}
      end)

      Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:snooze, seconds} = instruct(args(ctx), DateTime.utc_now())
      assert seconds > 0
      refute_received {:instructed, _, _, _}
      assert Stages.get(ctx.tenant.id, ctx.story_id).stage == :ci
    end

    test ":already_merged at the allowed head is adopted as control's ci -> merged", ctx do
      allow_source()
      now = DateTime.utc_now()
      assert {:ok, :pushed} = instruct(args(ctx), now)
      assert_received {:instructed, _, _, _}

      # The runner merged and its report never arrived; the resend's gate run finds it.
      stub_merged(@merge_sha)
      later = DateTime.add(now, MergeExecution.answer_window_seconds())

      assert {:ok, :adopted_merge} = instruct(args(ctx), later)
      refute_received {:instructed, _, _, _}

      row = Stages.get(ctx.tenant.id, ctx.story_id)
      assert row.stage == :merged
      assert row.merge_sha == @merge_sha
    end

    test "a repository on the change protocol cancels the job", ctx do
      set_source_mode(ctx, :chg)
      assert {:cancel, :change_protocol_enrolled} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
    end

    test "a row that moved on is not ready: nothing is gated or sent", ctx do
      assert {:ok, :not_ready} =
               instruct(
                 %{args(ctx) | "head_sha" => String.duplicate("f", 40)},
                 DateTime.utc_now()
               )

      set_verified_head(ctx, String.duplicate("f", 40))
      assert {:ok, :not_ready} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
    end
  end

  describe "once per head, and its bounds" do
    test "a pushed instruction is resent after the answer window, then escalates", ctx do
      allow_source()
      t0 = DateTime.utc_now()
      window = MergeExecution.answer_window_seconds()

      for n <- 1..MergeExecution.max_sends() do
        at = DateTime.add(t0, (n - 1) * window)
        assert {:ok, :pushed} = instruct(args(ctx), at)
        assert_received {:instructed, _, _, _}
        assert Stages.get(ctx.tenant.id, ctx.story_id).merge_instruction["sends"] == n
        # Never before the window.
        assert {:ok, :not_due} = instruct(args(ctx), DateTime.add(at, window - 1))
      end

      exhausted = DateTime.add(t0, MergeExecution.max_sends() * window)
      assert {:ok, :merge_unanswered} = instruct(args(ctx), exhausted)
      refute_received {:instructed, _, _, _}

      row = Stages.get(ctx.tenant.id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "merge_unanswered"
      assert row.escalation_reason =~ @head
      assert row.escalation_reason =~ ctx.runner.id
      assert "merge_unanswered" in (events(ctx, "transitioned") |> Enum.map(& &1.edge))
    end

    test "a refused push is recorded, retried after its own interval, and bounded", ctx do
      allow_source()
      t0 = DateTime.utc_now()
      retry = MergeExecution.refusal_retry_seconds()
      refuse = fn _tenant, _runner, _payload -> {:error, :runner_not_connected} end

      assert {:ok, {:not_pushed, :runner_not_connected}} =
               MergeExecution.instruct(args(ctx), now: t0, instruct: refuse)

      assert %{"outcome" => "runner_not_connected", "sends" => 0, "refusals" => 1} =
               Stages.get(ctx.tenant.id, ctx.story_id).merge_instruction

      assert {:ok, :not_due} =
               MergeExecution.instruct(args(ctx),
                 now: DateTime.add(t0, retry - 1),
                 instruct: refuse
               )

      for n <- 2..MergeExecution.max_refusals() do
        assert {:ok, {:not_pushed, :runner_not_connected}} =
                 MergeExecution.instruct(args(ctx),
                   now: DateTime.add(t0, (n - 1) * retry),
                   instruct: refuse
                 )
      end

      assert {:ok, :merge_unanswered} =
               MergeExecution.instruct(args(ctx),
                 now: DateTime.add(t0, MergeExecution.max_refusals() * retry),
                 instruct: refuse
               )

      assert Stages.get(ctx.tenant.id, ctx.story_id).escalation_reason =~ "runner_not_connected"
    end

    test "a stage row naming another runner than the claim's dispatch is not instructed", ctx do
      other = fixture(:stage_runner, %{tenant_id: ctx.tenant.id})
      set_stage(ctx, runner_id: other.id)
      allow_source()

      assert {:ok, {:not_pushed, :runner_mismatch}} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
    end

    test "a claim with no accepted dispatch at its epoch is not instructed", ctx do
      # The only accepted row is an older claim's.
      from(d in Loopctl.Runners.DispatchRecord, where: d.story_id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [claim_epoch: 7])

      allow_source()
      assert {:ok, {:not_pushed, :no_accepted_dispatch}} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
    end

    test "a new head is a new instruction, nothing carried over" do
      record = %{
        "head_sha" => String.duplicate("9", 40),
        "sends" => MergeExecution.max_sends(),
        "outcome" => "pushed",
        "sent_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      assert MergeExecution.instruction_due?(record, @head, DateTime.utc_now())
      refute MergeExecution.instruction_due?(nil, nil, DateTime.utc_now())
    end
  end

  describe "the sweep's selection" do
    test "an unverified head, a disabled driver and a chg project are not instructed", ctx do
      now = DateTime.utc_now()
      assert [:held] = sweep(ctx, now, enabled?: false)

      set_verified_head(ctx, nil)
      assert [:held] = sweep(ctx, now)
      refute_received {:enqueued, _}

      set_source_mode(ctx, :chg)
      assert [] = sweep(ctx, now)
    end

    test "a stage row naming no runner is not read", ctx do
      set_stage(ctx, runner_id: nil)
      assert [] = sweep(ctx, DateTime.utc_now())
    end

    test "a stage row of an older claim than the story's is not read", ctx do
      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [claim_epoch: 1])

      assert [] = sweep(ctx, DateTime.utc_now())
    end

    test "a story at another stage is not read", ctx do
      set_stage(ctx, stage: :reviewing)
      assert [] = sweep(ctx, DateTime.utc_now())
    end
  end

  describe "AC-48.17.3: the lease" do
    setup ctx do
      now = DateTime.utc_now()
      cap = DateTime.add(now, 60)
      claim(ctx, cap)
      set_dispatch_expiry(ctx, DateTime.add(now, 7_200))
      Map.put(ctx, :now, now)
    end

    test "a live runner's claim is held, forward, bounded by the hold", ctx do
      assert [:held] = sweep(ctx, ctx.now, enabled?: false)

      story = AdminRepo.get!(Story, ctx.story_id)
      expected = DateTime.add(ctx.now, MergeExecution.hold_seconds())
      assert DateTime.compare(story.claim_lease_cap, expected) == :eq
      assert DateTime.compare(story.claimed_until, expected) == :eq
      # The epoch is untouched, so an older claimant stays fenced.
      assert story.claim_epoch == 0
      assert [%AuditLog{actor_label: "control:merge_execution"}] = reanchored(ctx)
    end

    test "never past the implement dispatch's credential", ctx do
      ceiling = DateTime.add(ctx.now, 300)
      set_dispatch_expiry(ctx, ceiling)

      assert [:held] = sweep(ctx, ctx.now, enabled?: false)
      assert DateTime.compare(AdminRepo.get!(Story, ctx.story_id).claim_lease_cap, ceiling) == :eq
    end

    test "a cap already at the ceiling, or far from passing, is not written", ctx do
      claim(ctx, DateTime.add(ctx.now, MergeExecution.renew_within_seconds() + 60))
      assert [:held] = sweep(ctx, ctx.now, enabled?: false)
      assert reanchored(ctx) == []

      at_ceiling = DateTime.add(ctx.now, 30)
      claim(ctx, at_ceiling)
      set_dispatch_expiry(ctx, at_ceiling)
      assert [:held] = sweep(ctx, ctx.now, enabled?: false)
      assert reanchored(ctx) == []
    end

    test "an ended claim is not revived", ctx do
      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [agent_status: :reported_done])

      assert [:held] = sweep(ctx, ctx.now, enabled?: false)
      assert reanchored(ctx) == []
    end

    test "an absent runner's claim is not held", ctx do
      assert [:runner_absent] = sweep(ctx, ctx.now, live?: fn _, _ -> false end)
      assert reanchored(ctx) == []
    end
  end

  describe "AC-48.17.3: a runner that is gone" do
    test "is escalated over runner_gone past the bound, not re-queued", ctx do
      gone = fn _tenant, _runner -> false end
      t0 = DateTime.utc_now()
      bound = MergeExecution.runner_gone_after_seconds()

      assert [:runner_absent] = sweep(ctx, t0, live?: gone)
      assert %{"runner_id" => runner_id} = Stages.get(ctx.tenant.id, ctx.story_id).runner_absence
      assert runner_id == ctx.runner.id

      # The clock runs from the FIRST sighting, not the latest.
      assert [:runner_absent] = sweep(ctx, DateTime.add(t0, bound - 1), live?: gone)
      assert [:runner_gone] = sweep(ctx, DateTime.add(t0, bound), live?: gone)

      row = Stages.get(ctx.tenant.id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "runner_gone"
      assert row.escalation_reason =~ ctx.runner.id
      refute_received {:enqueued, _}
    end

    test "a row that changed runner under the decision is not escalated", ctx do
      t0 = DateTime.utc_now()
      bound = MergeExecution.runner_gone_after_seconds()
      assert [:runner_absent] = sweep(ctx, t0, live?: fn _, _ -> false end)

      other = fixture(:stage_runner, %{tenant_id: ctx.tenant.id})

      # Between the sweep's read and the escalation's lock, the row moves to another runner.
      moved = fn _tenant, _runner ->
        set_stage(ctx, runner_id: other.id)
        false
      end

      assert [:moved_on] = sweep(ctx, DateTime.add(t0, bound), live?: moved)
      assert Stages.get(ctx.tenant.id, ctx.story_id).stage == :ci
    end

    test "a runner seen live again clears its clock", ctx do
      t0 = DateTime.utc_now()
      bound = MergeExecution.runner_gone_after_seconds()

      assert [:runner_absent] = sweep(ctx, t0, live?: fn _, _ -> false end)
      assert [:held] = sweep(ctx, DateTime.add(t0, 10), enabled?: false)
      assert is_nil(Stages.get(ctx.tenant.id, ctx.story_id).runner_absence)

      assert [:runner_absent] = sweep(ctx, DateTime.add(t0, bound), live?: fn _, _ -> false end)
      assert Stages.get(ctx.tenant.id, ctx.story_id).stage == :ci
    end
  end

  describe "custody" do
    test "a halted tenant: the sweep writes nothing and the job snoozes", ctx do
      halt(ctx.tenant.id)
      allow_source()

      assert [{:skipped, :tenant_halted}] =
               sweep(ctx, DateTime.utc_now(), live?: fn _, _ -> false end)

      assert is_nil(Stages.get(ctx.tenant.id, ctx.story_id).runner_absence)

      assert {:snooze, _} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
    end

    test "a tenant that is not human-anchored is skipped and its job cancelled" do
      ctx = fixture(:merge_instruction_story, %{trust_tier: :agent_rooted})
      allow_source()

      assert [{:skipped, :custody_tier_required}] = sweep(ctx, DateTime.utc_now())
      assert {:cancel, :custody_tier_required} = instruct(args(ctx), DateTime.utc_now())
      refute_received {:instructed, _, _, _}
    end

    test "tenant isolation: another tenant's sweep and job reach none of these rows", ctx do
      other = fixture(:merge_instruction_story, %{head_sha: @head})
      allow_source()

      results = sweep(%{tenant: other.tenant}, DateTime.utc_now())
      assert results == [:instruction_enqueued]
      assert_received {:enqueued, %{"story_id" => story_id}}
      assert story_id == other.story_id

      # This tenant's story, under the other tenant's id: nothing is found to instruct.
      assert {:ok, :not_ready} =
               instruct(%{args(ctx) | "tenant_id" => other.tenant.id}, DateTime.utc_now())

      refute_received {:instructed, _, _, _}
      assert is_nil(Stages.get(ctx.tenant.id, ctx.story_id).merge_instruction)
    end
  end

  # --- helpers -------------------------------------------------------------------------

  defp args(ctx),
    do: %{"tenant_id" => ctx.tenant.id, "story_id" => ctx.story_id, "head_sha" => @head}

  defp sweep(ctx, now, opts \\ []) do
    test = self()

    MergeExecution.sweep(
      Keyword.merge(
        [
          now: now,
          tenant_id: ctx.tenant.id,
          live?: fn _tenant, _runner -> true end,
          enabled?: true,
          enqueue: fn args ->
            send(test, {:enqueued, args})
            :ok
          end
        ],
        opts
      )
    )
  end

  defp instruct(args, now) do
    test = self()

    MergeExecution.instruct(args,
      now: now,
      instruct: fn tenant_id, runner_id, payload ->
        send(test, {:instructed, tenant_id, runner_id, payload})
        :ok
      end
    )
  end

  defp events(ctx, event) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        Repo.all(
          from e in StageEvent,
            where: e.story_id == ^ctx.story_id and e.event == ^event,
            order_by: [asc: e.inserted_at]
        )
      end)

    rows
  end

  defp reanchored(ctx) do
    AdminRepo.all(
      from a in AuditLog,
        where: a.entity_id == ^ctx.story_id and a.action == "claim_lease_reanchored"
    )
  end

  defp claim(ctx, cap) do
    from(s in Story, where: s.id == ^ctx.story_id)
    |> AdminRepo.update_all(
      set: [agent_status: :implementing, claimed_until: cap, claim_lease_cap: cap]
    )
  end

  defp set_dispatch_expiry(ctx, at) do
    story = AdminRepo.get!(Story, ctx.story_id)

    from(d in Dispatch, where: d.id == ^story.implementer_dispatch_id)
    |> AdminRepo.update_all(set: [expires_at: at])
  end

  defp set_stage(ctx, set) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        from(s in StoryStage, where: s.story_id == ^ctx.story_id) |> Repo.update_all(set: set)
      end)
  end

  defp set_verified_head(ctx, sha), do: set_stage(ctx, verified_head_sha: sha)

  # A `chg` source carries its event secret and its root dispatch (the database's CHECK);
  # any dispatch of the tenant serves as the root here.
  defp set_source_mode(ctx, :chg) do
    story = AdminRepo.get!(Story, ctx.story_id)

    from(s in Source, where: s.project_id == ^ctx.project_id)
    |> AdminRepo.update_all(
      set: [
        mode: :chg,
        change_events_secret: "chg-secret",
        chg_root_dispatch_id: story.verifier_dispatch_id
      ]
    )
  end

  defp halt(tenant_id) do
    Tenant
    |> AdminRepo.get!(tenant_id)
    |> Ecto.Changeset.change(custody_halted_at: DateTime.utc_now())
    |> AdminRepo.update!()
  end

  defp allow_source,
    do: stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 10})

  defp stub_source(opts) do
    head = Keyword.get(opts, :head, @head)

    Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _number ->
      {:ok,
       %{
         state: "open",
         merged?: false,
         merge_sha: nil,
         head_sha: head,
         merge_base_sha: @base,
         diffstat: Keyword.fetch!(opts, :diffstat),
         diff: {:ok, %{files: Keyword.get(opts, :files, []), renames: []}}
       }}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
      {:ok, ["priv/rates/2026.csv", "lib/widgets_web/router.ex", "lib/widgets/thing.ex"]}
    end)
  end

  defp stub_merged(merge_sha) do
    Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _number ->
      {:ok,
       %{
         state: "closed",
         merged?: true,
         merge_sha: merge_sha,
         head_sha: @head,
         merge_base_sha: @head,
         diffstat: %{files: 1, changed_lines: 1},
         diff: {:ok, %{files: [], renames: []}}
       }}
    end)
  end
end
