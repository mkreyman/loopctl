defmodule Loopctl.Delivery.MergePreconditionIntegrationTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition.evaluate/3` and `enforce/3` end to end (issue #803).

  ## Why this module is `async: false` with committed rows

  The precondition reads the story, the intake source and the dispatch lineage on
  `AdminRepo` (as `Loopctl.Progress`, `Loopctl.Intake` and `Loopctl.Dispatches` all do) and
  the stage row on `Loopctl.Repo` (as `Loopctl.Delivery.Stages` does, and it is the only
  writer of that table). In production both see the same committed database. Under
  `Ecto.Adapters.SQL.Sandbox` each repo is a SEPARATE owner with its own transaction, so a
  row one repo inserted is invisible to the other and its FKs fail — measured, not assumed:
  a sandboxed `AdminRepo` tenant makes a `Repo` insert into `story_stages` fail
  `story_stages_tenant_id_fkey`.

  So the rows here are COMMITTED under a `fixture(:committed_tenant)`, exactly as
  `Loopctl.Delivery.StagesLockTest` does for its own reason, and the tenant is swept at
  module boundaries. Everything that can be tested without this — the whole decision, in
  `Loopctl.Delivery.MergePreconditionJudgeTest`, and the custody clause, in
  `Loopctl.Progress.MergeCustodyStatusTest` — is `async: true` and touches none of it.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.GateAInput
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @repo_files ["priv/rates/2026.csv", "lib/widgets_web/router.ex", "lib/widgets/thing.ex"]

  setup_all do
    full_sweep()
    on_exit(&full_sweep/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of DataCase's stubs, and several
    # dependencies resolve through Mox. `stub_all_defaults/0` is the shared set, called
    # directly as the `:scale` modules do. Global mode is safe in an `async: false` module.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # `fixture(:committed_tenant)` runs its own unboxed AdminRepo checkout, so it goes first.
    tenant = fixture(:committed_tenant, %{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    ctx = build_story(tenant)
    on_exit(fn -> purge_tenant(tenant.id) end)

    ctx
  end

  describe "evaluate/3" do
    test "resolves the repository, the pull request and the custody facts, and allows", ctx do
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 10})

      assert {:ok, %Verdict{decision: :allow} = verdict} = evaluate(ctx)
      assert verdict.repo == @repo
      assert verdict.pr_number == 4242
      assert verdict.head_sha == @head
      assert verdict.merge_base_sha == @base
      assert verdict.custody == :ok
    end

    test "resolves the repository from the story's intake source, never from the caller", ctx do
      # No intake source for this project: nothing else can name the repository, so the
      # gate refuses rather than judging the change against another repository's triggers.
      %{num_rows: 1} =
        AdminRepo.query!("DELETE FROM intake_sources WHERE project_id = $1", [
          Ecto.UUID.dump!(ctx.project_id)
        ])

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert Enum.any?(reasons, &match?({:repository_unresolved, {:no_intake_source, _}}, &1))
    end

    test "an unverified story is refused on the REAL custody facts", ctx do
      {1, _} =
        from(s in Story, where: s.id == ^ctx.story_id)
        |> AdminRepo.update_all(set: [verified_status: :unverified])

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:custody, :not_verified} in reasons
    end

    test "a forge failure that is NOT transient escalates rather than passing", ctx do
      Mox.stub(MockPullRequestSource, :pull_request, fn _repo, _n ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:pull_request_unavailable, {:github_api_error, 404}} in reasons
    end

    test "a story that is not in the tenant is :not_found", ctx do
      assert {:error, :not_found} =
               MergePrecondition.evaluate(ctx.tenant_id, Ecto.UUID.generate(), opts())
    end

    test "a story that is not at the ci stage is :wrong_stage", ctx do
      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in StoryStage, where: s.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [stage: :implementing])
        end)

      assert {:error, :wrong_stage} = evaluate(ctx)
    end
  end

  describe "enforce/3" do
    test "a refusal escalates on the merge_gate edge with a reason naming what failed", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})

      assert {:ok, %Verdict{decision: :refuse}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "merge_gate"
      assert row.escalation_reason =~ "human_path"
      assert row.attempts["merge_gate"] == 1
    end

    test "a lens contradiction's text never reaches the chained escalation reason", ctx do
      contradicted =
        Map.put(lens("story"), "contradicts", [
          %{"kind" => "kb", "ref" => "INJECTED-REF", "why" => "INJECTED-WHY"}
        ])

      set_lens_verdicts(ctx, %{
        "analyst" => lens("story"),
        "architect" => lens("story"),
        "engineer" => contradicted
      })

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})
      assert {:ok, %Verdict{decision: :refuse}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.escalation_reason =~ "contradiction"
      refute row.escalation_reason =~ "INJECTED"
      # loopctl's own vocabulary survives: the validated kind enum stays readable.
      assert row.escalation_reason =~ ~s("kb")
    end

    test "a human re-queueing a GATE A refusal satisfies Gate A at the next merge", ctx do
      set_lens_verdicts(ctx, %{
        "analyst" => lens("story"),
        "architect" => lens("story"),
        "engineer" => lens("escalate")
      })

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})
      assert {:ok, %Verdict{decision: :refuse, gate_a_inputs: :persisted_triage}} = enforce(ctx)

      {:ok, _row} = resolve_to_queued(ctx)

      assert GateAInput.for_story(ctx.tenant_id, ctx.story_id) == :human_resolution
    end

    test "a human re-queueing a refusal Gate A took no part in does not satisfy it", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})
      assert {:ok, %Verdict{decision: :refuse}} = enforce(ctx)

      {:ok, _row} = resolve_to_queued(ctx)

      assert {:persisted_triage, _outputs} = GateAInput.for_story(ctx.tenant_id, ctx.story_id)
    end

    test "an allow does not transition, and RECORDS itself against the head it judged", ctx do
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :ci
      # The allow is a recorded fact or it is not an allow: without this an already-merged
      # pull request could not be told from one merged around the gate.
      assert row.merge_gate_allowed_sha == @head
    end

    test "an allow is idempotent — the same head twice is the same allow", ctx do
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_allowed_sha == @head
    end

    test "an ALLOW that cannot be recorded becomes a refusal, and that refusal ESCALATES",
         ctx do
      # An allow nobody recorded is an allow nobody can later account for, so it must not
      # stand — AND the refusal it becomes has to take the same escalation path as any
      # other, or the caller is handed "refuse" over HTTP 200 while the story sits at `ci`
      # with nothing recorded.
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})
      conflicting_head = String.duplicate("9", 40)

      {:ok, _row} =
        Stages.record_effect(
          ctx.tenant_id,
          ctx.story_id,
          :merge_gate_allowed_sha,
          conflicting_head,
          claim_epoch: 0
        )

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:allow_not_recorded, :effect_conflict} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "allow_not_recorded"
    end

    test "an allow that cannot be recorded under a stale epoch cannot escalate either", ctx do
      # Both writes are fenced by the same epoch, so this one reports BOTH failures rather
      # than claiming an escalation it did not write.
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} =
               MergePrecondition.enforce(
                 ctx.tenant_id,
                 ctx.story_id,
                 Keyword.put(opts(), :claim_epoch, 99)
               )

      assert {:allow_not_recorded, :stale_claim_epoch} in reasons
      assert {:transition_failed, :escalated, :merge_gate, :stale_claim_epoch} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :ci
      assert is_nil(row.merge_gate_allowed_sha)
    end

    test "an already-merged head with NO recorded allow escalates as an ungated merge", ctx do
      merge_sha = String.duplicate("c", 40)
      stub_merged(merge_sha)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:ungated_merge, merge_sha, :no_recorded_allow} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "ungated_merge"
      # The sha the gate never authorised is named in the escalation, not lost.
      assert row.escalation_reason =~ merge_sha
    end

    test "an already-merged head the gate ALLOWED is adopted, not escalated", ctx do
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      merge_sha = String.duplicate("c", 40)
      stub_merged(merge_sha)

      assert {:ok, %Verdict{decision: :already_merged, merge_sha: ^merge_sha, reasons: []}} =
               enforce(ctx)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "a head that moved goes back to implementing, and takes the allow with it", ctx do
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      moved = String.duplicate("e", 40)

      stub_source(
        files: ["lib/widgets/thing.ex"],
        diffstat: %{files: 1, changed_lines: 1},
        head: moved
      )

      assert {:ok, %Verdict{decision: :head_moved, reasons: reasons}} = enforce(ctx)
      assert {:head_moved, moved, @head} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :implementing
      assert row.attempts["base_moved"] == 1
      # Both cleared: an allow that outlived its head would authorise an unjudged one.
      assert is_nil(row.head_sha)
      assert is_nil(row.merge_gate_allowed_sha)
    end

    test "a TRANSIENT forge fault transitions nothing, and is COUNTED", ctx do
      stub_unreachable()

      assert {:ok, %Verdict{decision: :unevaluated, reasons: reasons}} = enforce(ctx)
      assert {:pull_request_unavailable, {:github_unreachable, :timeout}} in reasons

      # One blip must not park a story on a human: `escalated` is human-only.
      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :ci
      assert row.merge_gate_unevaluated == %{"head_sha" => @head, "count" => 1}
    end

    test "a fault that never clears ESCALATES once it passes the bound", ctx do
      # The backstop under "no condition may retry for ever with nobody told".
      stub_unreachable()
      limit = MergePrecondition.max_consecutive_unevaluated()

      for _attempt <- 1..limit do
        assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
      end

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:unevaluated_limit_exceeded, limit + 1} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      # The escalation names the fault, not just the count.
      assert row.escalation_reason =~ "unevaluated_limit_exceeded"
      assert row.escalation_reason =~ "github_unreachable"
    end

    test "a verdict CLEARS the count a run of unevaluated results left behind", ctx do
      # Without this the count outlives the fault it recorded, and a later blip at the same
      # head escalates on a predecessor's arithmetic.
      stub_unreachable()
      assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
      assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_unevaluated["count"] == 2

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      assert is_nil(Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_unevaluated)
    end

    test "a HEAD-MOVED verdict is not masked by a rate-limited tree call", ctx do
      # The head-moved branch reads neither file list, so a fault in one must not turn an
      # ordinary push into an escalation once the unevaluated bound is reached.
      moved = String.duplicate("e", 40)

      Mox.stub(MockPullRequestSource, :pull_request, fn @repo, _number ->
        {:ok,
         %{
           state: "open",
           merged?: false,
           merge_sha: nil,
           head_sha: moved,
           merge_base_sha: @base,
           diffstat: %{files: 1, changed_lines: 1},
           diff: {:ok, %{files: ["lib/widgets/thing.ex"], renames: []}}
         }}
      end)

      Mox.stub(MockPullRequestSource, :repo_files, fn @repo, _ref ->
        flunk("the head-moved branch must not fetch a file list")
      end)

      assert {:ok, %Verdict{decision: :head_moved}} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :implementing
    end

    test "the count is kept per the RECORDED head, which is known when the forge is not",
         ctx do
      # The forge head is unknown when the pull request cannot be read at all, so keying on
      # it would collapse every story's count onto `null`. The reset-on-a-new-head half is
      # `Stages.note_unevaluated/4`'s own property and is tested there.
      stub_unreachable()

      assert {:ok, %Verdict{decision: :unevaluated, head_sha: nil, recorded_head_sha: @head}} =
               enforce(ctx)

      assert Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_unevaluated["head_sha"] == @head
    end

    test "a repeated refusal does not escalate twice", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})

      assert {:ok, %Verdict{decision: :refuse}} = enforce(ctx)
      # The row is at `escalated` now, so the second ask cannot even reach a verdict.
      assert {:error, :wrong_stage} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).attempts["merge_gate"] == 1
    end

    test "a long reason list is TRUNCATED so the escalation is still written", ctx do
      # The `story_stages_text_bounds` CHECK caps `escalation_reason` at 4000 characters. A
      # refusal whose reason list runs past it must still land: an over-long reason would
      # roll the transition back and leave the story sitting at `ci` with nothing recorded,
      # which is the one outcome a fail-closed gate cannot have. Two hundred unquotable
      # paths is the cheapest way to produce one — Gate B names each invalid path.
      files = for i <- 1..200, do: ~s(lib/widgets/"bad#{i}".ex)
      stub_source(files: files, diffstat: %{files: 200, changed_lines: 5})

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert length(reasons) > 100

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      # Bounded in CODEPOINTS with a margin under the 4000 the DB CHECK counts.
      assert row.escalation_reason |> String.to_charlist() |> length() == 3_900
      assert String.ends_with?(row.escalation_reason, "…")
    end

    test "a stale claim epoch cannot escalate, and the refusal still stands", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} =
               MergePrecondition.enforce(
                 ctx.tenant_id,
                 ctx.story_id,
                 Keyword.put(opts(), :claim_epoch, 99)
               )

      assert {:transition_failed, :escalated, :merge_gate, :stale_claim_epoch} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  describe "thread mode (US-45.4)" do
    @tree String.duplicate("e", 40)
    @base_tree String.duplicate("f", 40)
    # The comparison's merge base: what the judged three-dot diff is relative to, and so the
    # `base_sha` an allow records.
    @base_head String.duplicate("8", 40)

    setup ctx do
      # The claim's implement dispatch, PLACED in thread mode on `master`: the gate reads the
      # mode, the base branch and the branch from this row, never from the intake source.
      {_raw_key, runner} = fixture(:committed_runner, %{tenant_id: ctx.tenant_id})
      # The fixture's unboxed run gives up this process's AdminRepo checkout; take it back.
      checkout_admin()

      {:ok, dispatch_row} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.insert!(%Loopctl.Runners.DispatchRecord{
            tenant_id: ctx.tenant_id,
            runner_id: runner.id,
            dispatch_id: Ecto.UUID.generate(),
            story_id: ctx.story_id,
            claim_epoch: 0,
            kind: "implement",
            mode: "thread",
            base_branch: "master",
            # Released, so the row holds no slot and `runner_dispatches_unreleased_bounded`
            # has nothing to bound.
            status: "accepted",
            wall_clock_seconds: 3_600,
            released_at: DateTime.utc_now()
          })
        end)

      checkpoint =
        fixture(:thread_checkpoint, %{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story_id,
          seq: 1,
          commit_sha: @head,
          tree_sha: @tree
        })

      %{checkpoint: checkpoint, dispatch_row: dispatch_row}
    end

    test "TC-45.4.1 a claim placed in pr mode is untouched: it never reads a checkpoint", ctx do
      set_mode(ctx, "pr")
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      Mox.stub(MockPullRequestSource, :branch_head, fn _repo, _branch ->
        flunk("a pr-mode story read the thread branch")
      end)

      assert {:ok, %Verdict{decision: :allow, mode: :pr, pr_number: 4242}} = evaluate(ctx)
    end

    test "TC-45.4.2 a thread story at ci allows the recorded checkpoint, and the allow names it",
         ctx do
      stub_thread(ctx)

      assert {:ok, %Verdict{decision: :allow} = verdict} = enforce(ctx)
      assert verdict.mode == :thread
      assert verdict.pr_number == nil
      assert verdict.checkpoint_id == ctx.checkpoint.id
      assert verdict.checkpoint_sha == @head

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :ci
      assert row.merge_gate_allowed_sha == @head

      assert %{
               "payload" => %{
                 "checkpoint_id" => id,
                 "checkpoint_sha" => @head,
                 "base_sha" => @base_head
               }
             } = allow_event_data(ctx)

      assert verdict.merge_base_sha == @base_head

      assert id == ctx.checkpoint.id
    end

    test "TC-45.4.3 a branch head nobody reported goes back to implementing, unescalated", ctx do
      pushed = String.duplicate("9", 40)
      make_claim_live(ctx)
      stub_thread(ctx, branch_head: pushed)

      assert {:ok, %Verdict{decision: :head_moved, reasons: reasons}} = enforce(ctx)
      assert {:branch_head_unrecorded, pushed, @head} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :implementing
      assert row.attempts == %{"base_moved" => 1}
      assert row.escalation_reason == nil
    end

    test "TC-45.4.3 a checkpoint whose tree is the base's refuses empty_change", ctx do
      stub_thread(ctx, base_tree: @tree)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:empty_change, @tree} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).escalation_reason =~ "empty_change"
    end

    test "a moved head whose claim is NOT live escalates claim_not_live instead of looping",
         ctx do
      # The fixture story reported its work, so the claim no longer accepts checkpoints.
      pushed = String.duplicate("9", 40)
      stub_thread(ctx, branch_head: pushed)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert :claim_not_live in reasons
      assert {:branch_head_unrecorded, pushed, @head} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "a branch naming an EARLIER checkpoint of the claim is branch_head_regressed", ctx do
      make_claim_live(ctx)
      later = String.duplicate("5", 40)

      fixture(:thread_checkpoint, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        seq: 2,
        commit_sha: later,
        tree_sha: @tree
      })

      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in StoryStage, where: r.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [head_sha: later])
        end)

      # The branch went back to the claim's first checkpoint.
      stub_thread(ctx, head: later, branch_head: @head)

      assert {:ok, %Verdict{decision: :head_moved, reasons: reasons}} = enforce(ctx)
      assert {:branch_head_regressed, @head, later} in reasons
    end

    test "a thread branch the forge does not have goes back to implementing, branch_missing",
         ctx do
      make_claim_live(ctx)
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :branch_head, fn @repo, _branch ->
        {:error, {:github_api_error, 404}}
      end)

      # The repository reads, so the 404 is about the branch.
      Mox.stub(MockPullRequestSource, :repository_readable, fn @repo -> :ok end)

      assert {:ok, %Verdict{decision: :head_moved, reasons: reasons}} = enforce(ctx)
      assert {:branch_missing, @head} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :implementing
      assert row.escalation_reason == nil
    end

    test "the gate reads EXACTLY the branch the story's dispatch named", ctx do
      dispatched = "agent/story-4242-dispatched"
      set_dispatch(ctx, branch: dispatched)
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :branch_head, fn @repo, ^dispatched -> {:ok, @head} end)

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
    end

    # Round 3 finding 1: the stage row's `branch` survives a release, so after a re-claim onto
    # a machine declaring another prefix it names the EARLIER claim's branch. The current
    # claim's dispatched branch is the one judged.
    test "the current claim's dispatched branch wins over the stage row's earlier one", ctx do
      dispatched = "agent/dispatched"
      set_dispatch(ctx, branch: dispatched)

      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in StoryStage, where: r.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [branch: "loop/earlier-claim"])
        end)

      stub_thread(ctx)
      Mox.stub(MockPullRequestSource, :branch_head, fn @repo, ^dispatched -> {:ok, @head} end)

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
    end

    test "the MODE is the one the claim was PLACED under, whatever the source says now", ctx do
      # The source was switched to pr after placement; the story is still judged as a thread.
      {1, _} =
        from(s in Loopctl.Intake.Source, where: s.project_id == ^ctx.project_id)
        |> AdminRepo.update_all(set: [mode: :pr])

      stub_thread(ctx)

      assert {:ok, %Verdict{decision: :allow, mode: :thread}} = evaluate(ctx)
    end

    test "a route the ledger cannot answer is unevaluated with the mode UNKNOWN, never pr",
         ctx do
      test_pid = self()

      # A lock on the ledger held elsewhere: the route read waits out its lock_timeout and
      # answers :busy, so nothing is judged on a guessed route.
      holder =
        spawn(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          Repo.transaction(fn ->
            Repo.query!("LOCK TABLE runner_dispatches IN ACCESS EXCLUSIVE MODE")
            send(test_pid, :held)

            receive do
              :release -> :ok
            end
          end)

          Sandbox.checkin(Repo)
        end)

      assert_receive :held, 5_000
      on_exit(fn -> send(holder, :release) end)

      assert {:ok, %Verdict{decision: :unevaluated, mode: nil}} = evaluate(ctx)
      send(holder, :release)
    end

    test "a base that moved on since the checkpoint still allows, claim live or not", ctx do
      # The diff judged is the three-dot diff against the merge base; base freshness is the
      # merge executor's (US-45.5, AC-45.5.8), so the allow records THAT merge base.
      stub_thread(ctx, merge_base: @base)

      assert {:ok, %Verdict{decision: :allow, merge_base_sha: @base, reasons: []}} = enforce(ctx)
      assert %{"payload" => %{"base_sha" => @base}} = allow_event_data(ctx)
    end

    test "a checkpoint the base already CONTAINS is already_merged, with no merge_commit_sha",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      # Fast-forwarded (or merged) by hand: the merge base with the base IS the checkpoint.
      stub_thread(ctx, merge_base: @head)

      assert {:ok, %Verdict{decision: :already_merged, merge_sha: @head}} = evaluate(ctx)
    end

    test "a contained checkpoint whose recorded merge commit is NOT on the base is already_merged",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)
      stub_thread(ctx, merge_base: @head)
      Mox.stub(MockPullRequestSource, :contains?, fn @repo, ^merged, "master" -> {:ok, false} end)

      assert {:ok, %Verdict{decision: :already_merged, merge_sha: @head}} = evaluate(ctx)
    end

    test "an ungated fast-forward of the checkpoint is checkpoint_on_base_without_allow, never the ungated-merge alarm",
         ctx do
      stub_thread(ctx, merge_base: @head)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:checkpoint_on_base_without_allow, @head} in reasons
      refute Enum.any?(reasons, &match?({:ungated_merge, _, _}, &1))
      refute Enum.any?(reasons, &match?({:empty_change, _}, &1))
    end

    test "a checkpoint that IS the base it was cut from (no work) is checkpoint_on_base_without_allow",
         ctx do
      # Nothing was done: the checkpoint is the base commit, tree and all.
      stub_thread(ctx, merge_base: @head, base_tree: @tree)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:checkpoint_on_base_without_allow, @head} in reasons
      refute Enum.any?(reasons, &match?({:ungated_merge, _, _}, &1))
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "a deleted branch whose checkpoint the base contains is already_merged under its allow",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      stub_thread(ctx, merge_base: @head)
      stub_branch_deleted()

      assert {:ok, %Verdict{decision: :already_merged, merge_sha: @head}} = evaluate(ctx)
    end

    test "a deleted branch whose checkpoint the base contains, with no allow, is not merged",
         ctx do
      stub_thread(ctx, merge_base: @head)
      stub_branch_deleted()

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:checkpoint_on_base_without_allow, @head} in reasons
      refute Enum.any?(reasons, &match?({:branch_missing, _}, &1))
    end

    test "a deleted branch whose contained-check hits a TRANSIENT fault is unevaluated", ctx do
      stub_thread(ctx)
      stub_branch_deleted()

      Mox.stub(MockPullRequestSource, :compare, fn @repo, "master", @head ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:ok, %Verdict{decision: :unevaluated}} = evaluate(ctx)
    end

    # Round 3 finding 2: a claim nobody placed (a session claimed it and opened a PR) stays a
    # pull request when the source is flipped to thread; only LATER placements change route.
    test "a claim with NO accepted dispatch stays a pull request after the source flips to thread",
         ctx do
      {1, _} =
        from(s in Loopctl.Intake.Source, where: s.project_id == ^ctx.project_id)
        |> AdminRepo.update_all(set: [mode: :thread])

      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in Loopctl.Runners.DispatchRecord, where: r.id == ^ctx.dispatch_row.id)
          |> Repo.delete_all()
        end)

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :allow, mode: :pr, pr_number: 4242}} = evaluate(ctx)
    end

    test "a claim with NO accepted dispatch on a pr source is judged as a pull request", ctx do
      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in Loopctl.Runners.DispatchRecord, where: r.id == ^ctx.dispatch_row.id)
          |> Repo.delete_all()
        end)

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :allow, mode: :pr, pr_number: 4242}} = evaluate(ctx)
    end

    test "the BASE BRANCH is the one the claim was PLACED on, whatever the source says now",
         ctx do
      set_dispatch(ctx, base_branch: "trunk")

      {1, _} =
        from(s in Loopctl.Intake.Source, where: s.project_id == ^ctx.project_id)
        |> AdminRepo.update_all(set: [base_branch: "develop"])

      stub_thread(ctx, base_branch: "trunk")

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
    end

    test "a ledger row that pinned no base branch falls back to the source's current one",
         ctx do
      set_dispatch(ctx, base_branch: nil)

      {1, _} =
        from(s in Loopctl.Intake.Source, where: s.project_id == ^ctx.project_id)
        |> AdminRepo.update_all(set: [base_branch: "develop"])

      stub_thread(ctx, base_branch: "develop")

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
    end

    test "a merge_commit_sha GitHub cannot find is judged as open, never an escalation", ctx do
      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :contains?, fn @repo, ^merged, "master" ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:ok, %Verdict{decision: :allow, merge_sha: nil}} = enforce(ctx)
    end

    test "a TRANSIENT failure asking about a merge_commit_sha is unevaluated", ctx do
      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :contains?, fn @repo, ^merged, "master" ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
    end

    test "a branch 404 in a repository the token CANNOT read escalates, never branch_missing",
         ctx do
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :branch_head, fn @repo, _branch ->
        {:error, {:github_api_error, 404}}
      end)

      Mox.stub(MockPullRequestSource, :repository_readable, fn @repo ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:pull_request_unavailable, {:github_api_error, 404}} in reasons
      refute Enum.any?(reasons, &match?({:branch_missing, _}, &1))
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "a 404 on the commit once the branch names it escalates as pull_request_unavailable",
         ctx do
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :commit, fn @repo, @head ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = enforce(ctx)
      assert {:pull_request_unavailable, {:github_api_error, 404}} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "a checkpoint an ENDED claim recorded is not judged: claim_ended", ctx do
      {1, _} =
        from(s in Story, where: s.id == ^ctx.story_id)
        |> AdminRepo.update_all(set: [claim_epoch: 1])

      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in StoryStage, where: r.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [claim_epoch: 1])
        end)

      # The new claim was placed (thread mode, as before) and has recorded nothing yet.
      set_dispatch(ctx, claim_epoch: 1)

      stub_thread(ctx)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:claim_ended, :no_checkpoint_under_current_claim} in reasons
      refute Enum.any?(reasons, &match?({:no_checkpoint_recorded, _}, &1))
    end

    test "a branch naming another commit is judged without reading the checkpoint commit",
         ctx do
      make_claim_live(ctx)
      stub_thread(ctx, branch_head: String.duplicate("9", 40))

      Mox.stub(MockPullRequestSource, :commit, fn _repo, _sha ->
        flunk("the checkpoint commit was read although the branch already decided")
      end)

      assert {:ok, %Verdict{decision: :head_moved}} = enforce(ctx)
    end

    test "a merge_commit_sha the base does not contain is NOT already_merged", ctx do
      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :contains?, fn @repo, ^merged, "master" -> {:ok, false} end)

      assert {:ok, %Verdict{decision: :allow, merge_sha: nil}} = enforce(ctx)
    end

    test "a merge_commit_sha the base contains is already_merged under the recorded allow",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)
      Mox.stub(MockPullRequestSource, :contains?, fn @repo, ^merged, "master" -> {:ok, true} end)

      assert {:ok, %Verdict{decision: :already_merged, merge_sha: ^merged}} = evaluate(ctx)
    end

    test "any other head movement is still base_moved, back to implementing", ctx do
      make_claim_live(ctx)
      moved = String.duplicate("9", 40)

      fixture(:thread_checkpoint, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        seq: 2,
        commit_sha: moved,
        tree_sha: @tree,
        parent_checkpoint_id: ctx.checkpoint.id
      })

      stub_thread(ctx, head: moved)

      # A moved head is decided from the checkpoint alone: the file lists are never read.
      Mox.stub(MockPullRequestSource, :repo_files, fn _repo, _ref ->
        flunk("a moved head read the repository's file lists")
      end)

      assert {:ok, %Verdict{decision: :head_moved}} = enforce(ctx)
      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :implementing
      assert row.attempts == %{"base_moved" => 1}
    end
  end

  # The route the claim's dispatch was PLACED under — the one the gate reads (US-45.4). Written
  # to the ledger row directly: placement is `DispatchLedger.record_sent/4`'s, tested there.
  defp set_mode(ctx, mode), do: set_dispatch(ctx, mode: mode)

  defp set_dispatch(ctx, fields) do
    {:ok, {1, _}} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(r in Loopctl.Runners.DispatchRecord, where: r.id == ^ctx.dispatch_row.id)
        |> Repo.update_all(set: fields)
      end)
  end

  # The forge's view of the thread: the branch head, the checkpoint commit and the comparison
  # of the base with it. Each read asserts the ref it was asked for, so a gate reading the
  # wrong branch or comparing against the wrong base fails here rather than passing.
  defp stub_thread(ctx, opts \\ []) do
    head = Keyword.get(opts, :head, @head)

    stage = Stages.get(ctx.tenant_id, ctx.story_id)

    story = AdminRepo.get!(Story, ctx.story_id)
    {:ok, route} = DispatchPayload.dispatch_route(ctx.tenant_id, story)
    {:ok, branch} = DispatchPayload.thread_branch(route, story, stage.branch)

    Mox.stub(MockPullRequestSource, :branch_head, fn @repo, ^branch ->
      {:ok, Keyword.get(opts, :branch_head, head)}
    end)

    Mox.stub(MockPullRequestSource, :commit, fn @repo, ^head ->
      {:ok,
       %{
         tree_sha: Keyword.get(opts, :tree, @tree)
       }}
    end)

    base_branch = Keyword.get(opts, :base_branch, "master")

    Mox.stub(MockPullRequestSource, :compare, fn @repo, ^base_branch, ^head ->
      {:ok, comparison(Keyword.get(opts, :base_tree, @base_tree), opts)}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn @repo, _ref -> {:ok, @repo_files} end)
  end

  # The comparison, relative to `@base_head` unless `:merge_base` says otherwise.
  defp comparison(base_tree, opts) do
    %{
      merge_base_sha: Keyword.get(opts, :merge_base, @base_head),
      base_tree_sha: base_tree,
      diffstat: %{files: 1, changed_lines: 1},
      diff: {:ok, %{files: ["lib/widgets/thing.ex"], renames: []}}
    }
  end

  # A claim that still accepts checkpoints (`Loopctl.Delivery.Claimant.live?/2`): claimed,
  # its lease not run out, no review requested.
  defp make_claim_live(ctx) do
    {1, _} =
      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(
        set: [
          agent_status: :implementing,
          claimed_until: DateTime.add(DateTime.utc_now(), 3600),
          review_requested_at: nil
        ]
      )
  end

  # The thread branch 404s in a repository the token can read: deleted.
  defp stub_branch_deleted do
    Mox.stub(MockPullRequestSource, :branch_head, fn @repo, _branch ->
      {:error, {:github_api_error, 404}}
    end)

    Mox.stub(MockPullRequestSource, :repository_readable, fn @repo -> :ok end)
  end

  defp set_merge_commit(ctx, sha) do
    {:ok, {1, _}} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(c in Loopctl.Threads.Checkpoint, where: c.id == ^ctx.checkpoint.id)
        |> Repo.update_all(set: [merge_commit_sha: sha])
      end)
  end

  defp allow_event_data(ctx) do
    {:ok, data} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one(
          from e in Loopctl.Delivery.StageEvent,
            where:
              e.story_id == ^ctx.story_id and e.event == "effect_recorded" and
                fragment("?->>'effect'", e.data) == "merge_gate_allowed_sha",
            order_by: [desc: e.inserted_at],
            limit: 1,
            select: e.data
        )
      end)

    data
  end

  defp evaluate(ctx), do: MergePrecondition.evaluate(ctx.tenant_id, ctx.story_id, opts())
  defp enforce(ctx), do: MergePrecondition.enforce(ctx.tenant_id, ctx.story_id, opts())

  defp opts do
    [
      claim_epoch: 0,
      actor_label: "test",
      # Entering `escalated` is a CHAINED transition, and `Stages.advance/4` refuses one
      # that does not declare the actor's lineage. An operator key legitimately has none.
      actor_lineage: []
    ]
  end

  defp resolve_to_queued(ctx) do
    Escalations.resolve(ctx.tenant_id, ctx.story_id,
      to: :queued,
      actor_label: "test:operator",
      actor_role: :user,
      actor_lineage: []
    )
  end

  defp set_lens_verdicts(ctx, lens_verdicts) do
    {:ok, {1, _}} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(v in Loopctl.Delivery.TriageVerdictRecord, where: v.story_id == ^ctx.story_id)
        |> Repo.update_all(set: [lens_verdicts: lens_verdicts])
      end)
  end

  defp lens(outcome),
    do: %{
      "outcome" => outcome,
      "confidence" => "high",
      "escalation_reasons" => [],
      "contradicts" => []
    }

  defp stub_source(opts) do
    head = Keyword.get(opts, :head, @head)

    Mox.stub(MockPullRequestSource, :pull_request, fn @repo, _number ->
      {:ok,
       %{
         state: Keyword.get(opts, :state, "open"),
         merged?: false,
         merge_sha: nil,
         head_sha: head,
         merge_base_sha: @base,
         diffstat: Keyword.fetch!(opts, :diffstat),
         diff: {:ok, %{files: Keyword.get(opts, :files, []), renames: []}}
       }}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn @repo, _ref -> {:ok, @repo_files} end)
  end

  defp stub_unreachable do
    Mox.stub(MockPullRequestSource, :pull_request, fn @repo, _number ->
      {:error, {:github_unreachable, :timeout}}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn @repo, _ref ->
      {:error, {:github_unreachable, :timeout}}
    end)
  end

  defp stub_merged(merge_sha) do
    Mox.stub(MockPullRequestSource, :pull_request, fn @repo, _number ->
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

    Mox.stub(MockPullRequestSource, :repo_files, fn @repo, _ref -> {:ok, @repo_files} end)
  end

  defp build_story(tenant) do
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    verifier_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    fixture(:intake_source, %{
      tenant_id: tenant.id,
      project_id: project.id,
      repo_full_name: @repo
    })

    {:ok, %{dispatch: implementer}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

    {:ok, %{dispatch: verifier}} =
      Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: verifier_agent.id})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        verified_status: :verified,
        assigned_agent_id: agent.id,
        implementer_dispatch_id: implementer.id,
        verifier_dispatch_id: verifier.id
      })
      |> AdminRepo.update!()

    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :ci,
      claim_epoch: 0,
      pr_number: 4242,
      head_sha: @head
    })

    fixture(:triage_verdict, %{tenant_id: tenant.id, story_id: story.id})

    %{tenant_id: tenant.id, project_id: project.id, story_id: story.id}
  end

  # Three things block the sweep of a committed tenant, and all three are this module's own
  # committed test data: `dispatches` and `api_keys` have tenant FKs that do not cascade,
  # and `audit_chain` has one with a delete-BLOCKING trigger (entering `escalated` is a
  # chained transition, so every refusal appends to it).
  defp purge_tenant(tenant_id) do
    checkout_admin()
    purge_dependents("tenant_id = $1", [Ecto.UUID.dump!(tenant_id)])
  end

  # The same purge over every committed-runner tenant, then the tenants themselves. Run at
  # both module boundaries: an earlier run that died mid-test leaves rows behind, and the
  # sweep alone cannot delete a tenant they still reference.
  defp full_sweep do
    Sandbox.unboxed_run(AdminRepo, fn ->
      purge_dependents(
        "tenant_id IN (SELECT id FROM tenants WHERE slug LIKE 'committed-runner-%')",
        []
      )
    end)

    sweep_committed_runner_tenants()
  end

  # ONE transaction around the trigger toggle and the deletes: DDL is transactional in
  # Postgres, so a failing DELETE rolls the DISABLE back with it. Run as separate
  # autocommitted statements, a failure in the middle would leave the audit chain's
  # delete-blocking trigger OFF for the rest of the run, in a database every branch on this
  # box shares.
  defp purge_dependents(predicate, params) do
    {:ok, :ok} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!(
          "ALTER TABLE audit_chain DISABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        AdminRepo.query!("DELETE FROM audit_chain WHERE #{predicate}", params)

        # `stories` references both dispatch columns, so the refs go before the rows.
        AdminRepo.query!(
          "UPDATE stories SET implementer_dispatch_id = NULL, verifier_dispatch_id = NULL " <>
            "WHERE #{predicate}",
          params
        )

        AdminRepo.query!("DELETE FROM dispatches WHERE #{predicate}", params)
        AdminRepo.query!("DELETE FROM api_keys WHERE #{predicate}", params)

        AdminRepo.query!(
          "ALTER TABLE audit_chain ENABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        :ok
      end)

    :ok
  end

  defp checkout_admin do
    case Sandbox.checkout(AdminRepo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
