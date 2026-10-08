defmodule Loopctl.Delivery.MergePreconditionIntegrationTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition.evaluate/3` and `enforce/3` end to end (issue #803).

  The precondition reads the story, the intake source and the dispatch lineage on
  `AdminRepo` (as `Loopctl.Progress`, `Loopctl.Intake` and `Loopctl.Dispatches` all do) and
  the stage row on `Loopctl.Repo` (as `Loopctl.Delivery.Stages` does, and it is the only
  writer of that table). AdminRepo runs on Repo's sandbox connection in test
  (`Loopctl.AdminRepo.Route`), so both see this test's own rows and nothing here commits.

  The tests whose subject is a lock ANOTHER session holds (on the dispatch ledger, on the
  stage row) are `Loopctl.Delivery.MergePreconditionLockTest`. The whole decision without
  the database is `Loopctl.Delivery.MergePreconditionJudgeTest`, and the custody clause is
  `Loopctl.Progress.MergeCustodyStatusTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Delivery.GateAInput
  alias Loopctl.Delivery.MergeExecutor
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.MockMergeForge
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Repo
  alias Loopctl.Test.MergeForge
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ThreadMergeSweepWorker
  alias Loopctl.Workers.ThreadMergeWorker

  @repo MergeForge.repo()
  @head MergeForge.head()
  @base String.duplicate("b", 40)
  @repo_files ["priv/rates/2026.csv", "lib/widgets_web/router.ex", "lib/widgets/thing.ex"]

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
    fixture(:merge_ready_story, %{tenant_id: tenant.id, repo: @repo, head_sha: @head})
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

    test "#936: every forge read authenticates as the credential chosen for (tenant, repo)",
         ctx do
      test_pid = self()
      tenant_repo = ForgeRepo.tenant(@repo, "github_pat_tenant_0001")

      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn tenant_id, repo ->
        send(test_pid, {:asked, tenant_id, repo})
        {:ok, %Loopctl.Verification.Credential{kind: :tenant_token, repo: tenant_repo}}
      end)

      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 10})

      # Only the exact credential answers: an operator-token read of the same name would be a
      # FunctionClauseError here.
      Mox.stub(MockPullRequestSource, :pull_request, fn ^tenant_repo, 4242 ->
        send(test_pid, :pull_request_read_as_tenant)

        {:ok,
         %{
           state: "open",
           merged?: false,
           merge_sha: nil,
           head_sha: @head,
           merge_base_sha: @base,
           diffstat: %{files: 1, changed_lines: 10},
           diff: {:ok, %{files: ["lib/widgets/thing.ex"], renames: []}}
         }}
      end)

      Mox.stub(MockPullRequestSource, :repo_files, fn ^tenant_repo, _ref -> {:ok, @repo_files} end)

      assert {:ok, %Verdict{decision: :allow}} = evaluate(ctx)
      assert_received :pull_request_read_as_tenant
      assert_received {:asked, tenant_id, @repo}
      assert tenant_id == ctx.tenant_id
    end

    test "#936: no credential for the pair refuses naming it, and reads nothing", ctx do
      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      Mox.stub(MockPullRequestSource, :pull_request, fn _repo, _n ->
        flunk("the forge was called with no credential")
      end)

      Mox.stub(MockPullRequestSource, :repo_files, fn _repo, _ref ->
        flunk("the forge was called with no credential")
      end)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:pull_request_unavailable, :credential_unavailable} in reasons
    end

    test "#936: no PR number AND no credential refuses naming both", ctx do
      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in StoryStage, where: r.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [pr_number: nil])
        end)

      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:pull_request_unavailable, :credential_unavailable} in reasons
      assert Enum.any?(reasons, &match?({:no_pull_request_recorded, _}, &1))
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

      Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _number ->
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

      Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
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
    @tree MergeForge.tree()
    @base_tree MergeForge.base_tree()
    # The comparison's merge base: what the judged three-dot diff is relative to, and so the
    # `base_sha` an allow records.
    @base_head MergeForge.base_head()

    setup :thread_setup

    test "#936: a thread with no credential for its repository refuses naming it, unread", ctx do
      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      for call <- [:branch_head, :commit, :compare, :contains?, :check_evidence] do
        arity = if call in [:branch_head, :commit], do: 2, else: 3
        stub_flunk(call, arity)
      end

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:pull_request_unavailable, :credential_unavailable} in reasons
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

    # TC-45.6.1: green on the PARENT, pending on the checkpoint: the gate reads the
    # checkpoint's own commit and nothing else, so it does not allow.
    test "TC-45.6.1 CI is read for the checkpoint's exact SHA; green on another commit is not an allow",
         ctx do
      stub_thread(ctx)
      parent = String.duplicate("b", 40)

      Mox.stub(MockPullRequestSource, :check_evidence, fn %ForgeRepo{full_name: @repo},
                                                          sha,
                                                          _branch ->
        cond do
          sha == @head -> {:ok, %{jobs: [ci_run("test", nil, "in_progress")], statuses: []}}
          sha == parent -> {:ok, %{jobs: [ci_run("test", "success")], statuses: []}}
        end
      end)

      assert {:ok, %Verdict{decision: :unevaluated} = verdict} = enforce(ctx)
      assert {:required_check_pending, "test"} in verdict.reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_allowed_sha == nil
    end

    # #910 round 3, finding 1: read_at is stamped when the read STARTS.
    test "the evidence's read_at is when the read began, not when it returned", ctx do
      stub_thread(ctx)
      test_pid = self()

      Mox.stub(MockPullRequestSource, :check_evidence, fn %ForgeRepo{full_name: @repo},
                                                          _sha,
                                                          _branch ->
        send(test_pid, {:reading_at, DateTime.utc_now()})
        Process.sleep(20)
        {:ok, %{jobs: [ci_run("test", "success")], statuses: []}}
      end)

      assert {:ok, %Verdict{decision: :allow} = verdict} = enforce(ctx)
      assert_received {:reading_at, reading_at}
      {:ok, read_at, _} = DateTime.from_iso8601(verdict.ci_evidence["read_at"])
      assert DateTime.compare(read_at, reading_at) != :gt
    end

    # #910 round 3, finding 5: a CI wait decides nothing and copies nothing.
    test "a CI wait copies no evidence onto the checkpoint", ctx do
      stub_thread(ctx, ci: %{jobs: [ci_run("test", nil, "queued")], statuses: []})

      assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
      refute Map.has_key?(checkpoint_evidence(ctx), "ci")
    end

    # AC-45.6.1: whatever the decision, the evidence read is copied onto the checkpoint.
    test "the evidence is copied onto the checkpoint on an allow and on a refusal", ctx do
      stub_thread(ctx)

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      assert %{"ci" => %{"sha" => @head, "passed" => ["test"], "failed" => []}} =
               checkpoint_evidence(ctx)

      stub_thread(ctx, ci: %{jobs: [ci_run("test", "failure")], statuses: []})
      reset_allow(ctx)

      assert {:ok, %Verdict{decision: :refuse} = refused} = enforce(ctx)
      assert {:required_check_failed, "test", "failure"} in refused.reasons

      assert %{"ci" => %{"failed" => [%{"name" => "test", "why" => "failure"}]}} =
               checkpoint_evidence(ctx)
    end

    # Review round 1, findings 1 and 2: a CI wait is bounded in TIME from the checkpoint,
    # never by polls, so a slow pipeline never escalates and a stuck one still does.
    test "a CI wait never reaches the unevaluated bound; past the time limit it escalates", ctx do
      for ci <- [
            %{jobs: [ci_run("test", nil, "queued")], statuses: []},
            %{jobs: [], statuses: []}
          ] do
        stub_thread(ctx, ci: ci)

        for _ <- 1..(MergePrecondition.max_consecutive_unevaluated() + 2) do
          assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
        end

        assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
      end

      # The wait is measured from the story's entry into `ci`, not from the checkpoint.
      entered =
        DateTime.add(DateTime.utc_now(), -(MergePrecondition.ci_wait_limit_seconds() + 60))

      enter_ci_at(ctx, entered)

      assert {:ok, %Verdict{decision: :refuse} = verdict} = enforce(ctx)
      assert {:required_check_timed_out, "test", :missing} in verdict.reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    # Round 3: the required checks are the source's CURRENT list, so correcting the list
    # (a renamed job) reaches a story already in flight.
    test "the required checks are the source's current list, read live", ctx do
      stub_thread(ctx, ci: %{jobs: [ci_run("unit", "success")], statuses: []})

      assert {:ok, %Verdict{decision: :unevaluated} = waiting} = enforce(ctx)
      assert {:required_check_missing, "test"} in waiting.reasons

      {1, _} =
        from(src in Loopctl.Intake.Source, where: src.project_id == ^ctx.project_id)
        |> AdminRepo.update_all(set: [required_checks: ["unit"]])

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
    end

    # Review round 2, finding 7: a completed CI wait ends a run of transient faults.
    test "a CI wait between forge faults resets their consecutive count", ctx do
      stub_thread(ctx)
      blips = MergePrecondition.max_consecutive_unevaluated() - 1

      fault = fn ->
        Mox.stub(MockPullRequestSource, :check_evidence, fn %ForgeRepo{full_name: @repo},
                                                            _sha,
                                                            _branch ->
          {:error, {:github_unreachable, :timeout}}
        end)

        for _ <- 1..blips, do: assert({:ok, %Verdict{decision: :unevaluated}} = enforce(ctx))
      end

      fault.()

      Mox.stub(MockPullRequestSource, :check_evidence, fn %ForgeRepo{full_name: @repo},
                                                          _sha,
                                                          _branch ->
        {:ok, %{jobs: [ci_run("test", nil, "queued")], statuses: []}}
      end)

      assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)

      fault.()
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    # Round 1 of #910, finding 8: with no recorded entry into ci, the wait is measured from the
    # checkpoint's recording, so it is bounded for every story.
    test "a story with no recorded ci entry is bounded from its checkpoint instead", ctx do
      stub_thread(ctx, ci: %{jobs: [], statuses: []})

      recorded =
        DateTime.add(DateTime.utc_now(), -(MergePrecondition.ci_wait_limit_seconds() + 60))

      {1, _} =
        from(c in Loopctl.Threads.Checkpoint, where: c.id == ^ctx.checkpoint.id)
        |> AdminRepo.update_all(set: [inserted_at: recorded])

      assert {:ok, %Verdict{decision: :refuse} = verdict} = enforce(ctx)
      assert {:required_check_timed_out, "test", :missing} in verdict.reasons
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

    test "round 2, finding 5: an unrecorded head merged onto the ALLOWED checkpoint is a base update in flight",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      in_flight = String.duplicate("7", 40)
      stub_thread(ctx, branch_head: in_flight)

      Mox.stub(MockPullRequestSource, :commit, fn
        %ForgeRepo{full_name: @repo}, @head ->
          {:ok, %{tree_sha: @tree, parents: [@base_head]}}

        %ForgeRepo{full_name: @repo}, ^in_flight ->
          {:ok, %{tree_sha: @tree, parents: [@head, @base_head]}}
      end)

      # Its second parent is on the base branch: the executor's own merge.
      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     sha,
                                                     "master" ->
        {:ok, sha == @base_head}
      end)

      # Evaluated, not enforced: the verdict is a retry, never a moved head.
      assert {:ok, %Verdict{decision: :unevaluated, reasons: reasons}} = evaluate(ctx)
      assert inspect(reasons) =~ "base_update_in_flight"

      # Two parents, the second NOT on the base: somebody's merge, a moved head.
      Mox.stub(MockPullRequestSource, :commit, fn
        %ForgeRepo{full_name: @repo}, @head ->
          {:ok, %{tree_sha: @tree, parents: [@base_head]}}

        %ForgeRepo{full_name: @repo}, ^in_flight ->
          {:ok, %{tree_sha: @tree, parents: [@head, @base]}}
      end)

      assert {:ok, %Verdict{decision: decision}} = evaluate(ctx)
      assert decision in [:head_moved, :refuse]
    end

    test "round 3, finding 6: an unreadable extra commit read on an unrecorded head is still head_moved",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
      make_claim_live(ctx)

      pushed = String.duplicate("7", 40)
      stub_thread(ctx, branch_head: pushed)

      Mox.stub(MockPullRequestSource, :commit, fn
        %ForgeRepo{full_name: @repo}, @head -> {:ok, %{tree_sha: @tree, parents: [@base_head]}}
        %ForgeRepo{full_name: @repo}, ^pushed -> {:error, {:github_api_error, 404}}
      end)

      assert {:ok, %Verdict{decision: :head_moved}} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :implementing
    end

    test "round 2, finding 5: a claimant's single-parent commit on the allowed checkpoint is head_moved",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)
      make_claim_live(ctx)

      pushed = String.duplicate("7", 40)
      stub_thread(ctx, branch_head: pushed)

      Mox.stub(MockPullRequestSource, :commit, fn
        %ForgeRepo{full_name: @repo}, @head -> {:ok, %{tree_sha: @tree, parents: [@base_head]}}
        %ForgeRepo{full_name: @repo}, ^pushed -> {:ok, %{tree_sha: @tree, parents: [@head]}}
      end)

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     _sha,
                                                     "master" ->
        {:ok, true}
      end)

      assert {:ok, %Verdict{decision: :head_moved, reasons: reasons}} = enforce(ctx)
      assert {:branch_head_unrecorded, pushed, @head} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :implementing
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

      Mox.stub(MockPullRequestSource, :branch_head, fn %ForgeRepo{full_name: @repo}, _branch ->
        {:error, {:github_api_error, 404}}
      end)

      # The repository reads, so the 404 is about the branch.
      Mox.stub(MockPullRequestSource, :repository_readable, fn %ForgeRepo{full_name: @repo} ->
        :ok
      end)

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

      Mox.stub(MockPullRequestSource, :branch_head, fn %ForgeRepo{full_name: @repo},
                                                       ^dispatched ->
        {:ok, @head}
      end)

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

      Mox.stub(MockPullRequestSource, :branch_head, fn %ForgeRepo{full_name: @repo},
                                                       ^dispatched ->
        {:ok, @head}
      end)

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

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     ^merged,
                                                     "master" ->
        {:ok, false}
      end)

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

      Mox.stub(MockPullRequestSource, :compare, fn %ForgeRepo{full_name: @repo},
                                                   "master",
                                                   @head ->
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

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     ^merged,
                                                     "master" ->
        {:error, {:github_api_error, 404}}
      end)

      assert {:ok, %Verdict{decision: :allow, merge_sha: nil}} = enforce(ctx)
    end

    test "a TRANSIENT failure asking about a merge_commit_sha is unevaluated", ctx do
      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     ^merged,
                                                     "master" ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:ok, %Verdict{decision: :unevaluated}} = enforce(ctx)
    end

    test "a branch 404 in a repository the token CANNOT read escalates, never branch_missing",
         ctx do
      stub_thread(ctx)

      Mox.stub(MockPullRequestSource, :branch_head, fn %ForgeRepo{full_name: @repo}, _branch ->
        {:error, {:github_api_error, 404}}
      end)

      Mox.stub(MockPullRequestSource, :repository_readable, fn %ForgeRepo{full_name: @repo} ->
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

      Mox.stub(MockPullRequestSource, :commit, fn %ForgeRepo{full_name: @repo}, @head ->
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

    test "#936: no credential AND an ended claim refuses naming BOTH", ctx do
      {1, _} =
        from(s in Story, where: s.id == ^ctx.story_id)
        |> AdminRepo.update_all(set: [claim_epoch: 1])

      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(r in StoryStage, where: r.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [claim_epoch: 1])
        end)

      set_dispatch(ctx, claim_epoch: 1)

      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:claim_ended, :no_checkpoint_under_current_claim} in reasons
      assert {:pull_request_unavailable, :credential_unavailable} in reasons
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

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     ^merged,
                                                     "master" ->
        {:ok, false}
      end)

      assert {:ok, %Verdict{decision: :allow, merge_sha: nil}} = enforce(ctx)
    end

    test "a merge_commit_sha the base contains is already_merged under the recorded allow",
         ctx do
      stub_thread(ctx)
      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      merged = String.duplicate("6", 40)
      set_merge_commit(ctx, merged)

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     ^merged,
                                                     "master" ->
        {:ok, true}
      end)

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

  describe "merge executor (US-45.5)" do
    @merge MergeForge.merge()
    @moved_base String.duplicate("9", 40)
    @base_update String.duplicate("d", 40)
    @base_update_tree String.duplicate("7", 40)
    @session MergeForge.session()

    setup :thread_setup

    setup ctx do
      # A recorded thread-mode allow for the checkpoint, exactly as the gate records one: the
      # row's allow and the event naming the checkpoint and the merge base.
      MergeForge.record_thread_allow(ctx, ctx.checkpoint, @head)
      story = AdminRepo.get!(Story, ctx.story_id)
      {:ok, route} = DispatchPayload.dispatch_route(ctx.tenant_id, story)
      {:ok, branch} = DispatchPayload.thread_branch(route, story, nil)
      MergeForge.stub_forge(branch)
      %{branch: branch}
    end

    test "squashes the checkpoint's tree onto the base head and moves the story to merged", ctx do
      test_pid = self()

      Mox.stub(MockMergeForge, :create_commit, fn @session, commit ->
        send(test_pid, {:created, commit})
        {:ok, @merge}
      end)

      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge ->
        # AC-45.5.2: the squash commit is RECORDED before the ref moves.
        send(test_pid, {:recorded_before_ref, merge_commit(ctx)})
        :ok
      end)

      assert {:merged, @merge} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert_received {:created, %{tree: @tree, parents: [@base_head], message: message}}
      assert message =~ "Loopctl-Story: #{ctx.story_id}"
      assert_received {:recorded_before_ref, @merge}

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :merged and row.merge_sha == @merge
    end

    test "TC-45.5.1 a ref update whose acknowledgement was lost is already_merged on the retry",
         ctx do
      # The update landed and the answer was lost: a transient fault, retried.
      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:retry, {:github_unreachable, :timeout}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
      assert merge_commit(ctx) == @merge

      # The retry finds the base moved ON — past the merge commit — and asks whether the
      # recorded commit is an ancestor of it, not whether the trees match.
      MergeForge.stub_base_head(@moved_base)
      MergeForge.stub_ancestors(%{{@merge, @moved_base} => true})

      Mox.stub(MockMergeForge, :create_commit, fn _session, _commit ->
        flunk("an already-merged checkpoint is not squashed again")
      end)

      assert {:already_merged, @merge} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :merged and row.merge_sha == @merge
    end

    test "finding 4: a checkpoint the base already contains (a gated fast-forward) is adopted",
         ctx do
      MergeForge.stub_ancestors(%{{@head, @base_head} => true})
      Mox.stub(MockMergeForge, :create_commit, fn _s, _c -> flunk("nothing to squash") end)

      assert {:already_merged, @head} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :merged and row.merge_sha == @head
    end

    test "round 2, finding 3: a transient failure reading the recorded squash retries, never re-mints",
         ctx do
      set_merge_commit(ctx, @merge)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head -> {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}
        @session, @base_head -> {:ok, %{sha: @base_head, tree_sha: @base_tree, parents: []}}
        @session, @merge -> {:error, {:github_unreachable, :timeout}}
      end)

      Mox.stub(MockMergeForge, :create_commit, fn _s, _c -> flunk("no second squash") end)

      assert {:retry, {:github_unreachable, :timeout}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert merge_commit(ctx) == @merge
    end

    test "round 2, finding 1: another run's recorded squash is converged on, not escalated",
         ctx do
      other = String.duplicate("6", 40)

      Mox.stub(MockMergeForge, :create_commit, fn @session, _commit ->
        set_merge_commit(ctx, other)
        {:ok, @merge}
      end)

      Mox.stub(MockMergeForge, :update_ref, fn _s, _b, _sha -> flunk("no ref update") end)

      assert {:skipped, {:not_mergeable, :merge_commit_moved}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "a retry on an unmoved base reuses the commit it recorded rather than minting another",
         ctx do
      set_merge_commit(ctx, @merge)
      MergeForge.stub_ancestors(%{{@merge, @base_head} => false, {@base_head, @head} => true})

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head -> {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}
        @session, @base_head -> {:ok, %{sha: @base_head, tree_sha: @base_tree, parents: []}}
        @session, @merge -> {:ok, %{sha: @merge, tree_sha: @tree, parents: [@base_head]}}
      end)

      Mox.stub(MockMergeForge, :create_commit, fn _session, _commit ->
        flunk("the recorded squash commit is reused")
      end)

      assert {:merged, @merge} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "finding 1: a story that left ci before the ref update is never merged", ctx do
      test_pid = self()

      # The story is released between the run's read and its fenced write.
      Mox.stub(MockMergeForge, :create_commit, fn @session, _commit ->
        set_stage(ctx, :queued)
        {:ok, @merge}
      end)

      Mox.stub(MockMergeForge, :update_ref, fn _s, _b, _sha ->
        send(test_pid, :ref_moved)
        :ok
      end)

      assert {:skipped, {:not_mergeable, {:not_at_ci, :queued}}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      refute_received :ref_moved
      assert is_nil(merge_commit(ctx))
    end

    test "finding 1: an allow withdrawn before the ref update is never merged", ctx do
      Mox.stub(MockMergeForge, :create_commit, fn @session, _commit ->
        reset_allow(ctx)
        {:ok, @merge}
      end)

      Mox.stub(MockMergeForge, :update_ref, fn _s, _b, _sha -> flunk("no ref update") end)

      assert {:skipped, {:not_mergeable, :allow_withdrawn}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "finding 1: a merge whose stage write fails escalates naming the sha, from where the story is",
         ctx do
      # The ref moved, then the story was released before `ci -> merged` could be written.
      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge ->
        set_stage(ctx, :queued)
        :ok
      end)

      assert {:escalated, {{:merged_not_recorded, :stale_stage}, @merge}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ @merge
    end

    test "finding 1: a later run that finds the recorded squash on the base outside ci escalates it",
         ctx do
      set_merge_commit(ctx, @merge)
      set_stage(ctx, :implementing)
      MergeForge.stub_ancestors(%{{@merge, @base_head} => true})

      assert {:escalated, {:merged_outside_ci, @merge}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "merged_outside_ci"

      # Not on the base: ordinary, and skipped.
      set_stage(ctx, :implementing)
      MergeForge.stub_ancestors(%{})

      assert {:skipped, {:not_at_ci, :implementing}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "#936: the orphan check opens no App session for a pair with no credential", ctx do
      set_merge_commit(ctx, @merge)
      set_stage(ctx, :implementing)

      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      Mox.stub(MockMergeForge, :session, fn _repo -> flunk("the App opened a session") end)

      assert {:skipped, {:not_at_ci, :implementing}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "TC-45.5.2 a refused fast-forward merges the base into the thread: base_update, story at ci",
         ctx do
      test_pid = self()
      verified_before = AdminRepo.get!(Story, ctx.story_id).verified_status
      stub_base_update(ctx, test_pid)

      assert :base_updated = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      # Finding 8: a temporary branch AT the checkpoint takes the merge, the thread branch is
      # fast-forwarded to it, and the temporary branch is deleted.
      assert_received {:temp_created, temp, @head}
      assert String.starts_with?(temp, "loop/loopctl-base-update-")
      assert_received {:merged_into, ^temp}
      assert_received {:thread_moved, @base_update}
      assert_received {:temp_deleted, ^temp}

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :ci
      assert row.head_sha == @base_update
      assert is_nil(row.merge_gate_allowed_sha)
      assert row.attempts == %{"base_updated" => 1}

      assert {:ok, %{latest: %{kind: :base_update, commit_sha: @base_update} = latest}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story_id)

      assert latest.parent_checkpoint_id == ctx.checkpoint.id
      assert AdminRepo.get!(Story, ctx.story_id).verified_status == verified_before
    end

    test "finding 8: a thread branch pushed to during the base update is base_moved, nothing recorded",
         ctx do
      make_claim_live(ctx)
      test_pid = self()
      stub_base_update(ctx, test_pid)
      branch = ctx.branch

      Mox.stub(MockMergeForge, :update_ref, fn
        @session, "master", @merge -> {:error, :not_fast_forward}
        @session, ^branch, @base_update -> {:error, :not_fast_forward}
      end)

      assert {:base_moved, :thread_branch_moved} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
      assert_received {:temp_deleted, _temp}

      assert {:ok, %{latest: %{id: id}}} = Threads.claim_checkpoints(ctx.tenant_id, ctx.story_id)
      assert id == ctx.checkpoint.id
    end

    test "round 2, finding 5: a retry recognises its own unrecorded base update and records it",
         ctx do
      head = @base_update
      branch = ctx.branch
      stub_base_update(ctx, self())

      Mox.stub(MockMergeForge, :branch_head, fn
        @session, "master" -> {:ok, @moved_base}
        @session, ^branch -> {:ok, head}
      end)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head ->
          {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}

        @session, ^head ->
          {:ok, %{sha: head, tree_sha: @base_update_tree, parents: [@head, @moved_base]}}

        @session, sha ->
          {:ok, %{sha: sha, tree_sha: @base_tree, parents: []}}
      end)

      MergeForge.stub_ancestors(%{
        {@base_head, @head} => true,
        {@moved_base, @moved_base} => true
      })

      # GitHub merges that same base commit into the checkpoint again: the identical tree.
      Mox.stub(MockMergeForge, :merge, fn @session,
                                          "loop/loopctl-base-update-" <> _,
                                          @moved_base,
                                          _m ->
        {:ok,
         %{
           sha: String.duplicate("2", 40),
           tree_sha: @base_update_tree,
           parents: [@head, @moved_base]
         }}
      end)

      assert :base_updated = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :ci and row.head_sha == head
    end

    test "round 2, finding 5: a merge commit with the right parents but another tree is not adopted",
         ctx do
      make_claim_live(ctx)
      head = @base_update
      branch = ctx.branch
      stub_base_update(ctx, self())

      Mox.stub(MockMergeForge, :branch_head, fn
        @session, "master" -> {:ok, @moved_base}
        @session, ^branch -> {:ok, head}
      end)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head ->
          {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}

        @session, ^head ->
          {:ok, %{sha: head, tree_sha: @base_update_tree, parents: [@head, @moved_base]}}

        @session, sha ->
          {:ok, %{sha: sha, tree_sha: @base_tree, parents: []}}
      end)

      MergeForge.stub_ancestors(%{
        {@base_head, @head} => true,
        {@moved_base, @moved_base} => true
      })

      Mox.stub(MockMergeForge, :merge, fn @session, _temp, @moved_base, _m ->
        {:ok,
         %{sha: String.duplicate("2", 40), tree_sha: @base_tree, parents: [@head, @moved_base]}}
      end)

      assert {:base_moved, {:thread_branch_moved, ^head}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert {:ok, %{latest: %{id: id}}} = Threads.claim_checkpoints(ctx.tenant_id, ctx.story_id)
      assert id == ctx.checkpoint.id
    end

    test "round 2, finding 5: a merge commit whose second parent is not on the base is not adopted",
         ctx do
      make_claim_live(ctx)
      head = @base_update
      branch = ctx.branch
      stub_base_update(ctx, self())

      Mox.stub(MockMergeForge, :branch_head, fn
        @session, "master" -> {:ok, @moved_base}
        @session, ^branch -> {:ok, head}
      end)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head ->
          {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}

        @session, ^head ->
          {:ok, %{sha: head, tree_sha: @base_update_tree, parents: [@head, @moved_base]}}

        @session, sha ->
          {:ok, %{sha: sha, tree_sha: @base_tree, parents: []}}
      end)

      # The second parent is NOT an ancestor of the base head: not a merge of the base.
      MergeForge.stub_ancestors(%{{@base_head, @head} => true})

      Mox.stub(MockMergeForge, :merge, fn @session, _temp, @moved_base, _m ->
        {:ok,
         %{
           sha: String.duplicate("2", 40),
           tree_sha: @base_update_tree,
           parents: [@head, @moved_base]
         }}
      end)

      assert {:base_moved, {:thread_branch_moved, ^head}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "finding 5: past the bound on consecutive base updates it escalates base_churn", ctx do
      # Three base updates of the same change, the last one allowed and judged.
      chain =
        Enum.reduce(1..3, ctx.checkpoint, fn n, parent ->
          fixture(:thread_checkpoint, %{
            tenant_id: ctx.tenant_id,
            story_id: ctx.story_id,
            seq: n + 1,
            kind: :base_update,
            commit_sha: String.duplicate("#{n}", 40),
            parent_checkpoint_id: parent.id
          })
        end)

      reset_allow(ctx)
      MergeForge.record_thread_allow(ctx, chain, chain.commit_sha)
      set_head(ctx, chain.commit_sha)
      MergeForge.stub_base_head(@moved_base)

      Mox.stub(MockMergeForge, :commit, fn
        @session, sha -> {:ok, %{sha: sha, tree_sha: @tree, parents: [@base_head]}}
      end)

      Mox.stub(MockMergeForge, :create_ref, fn _s, _b, _sha -> flunk("no fourth base update") end)

      max = MergeExecutor.max_consecutive_base_updates()
      assert {:escalated, {:base_churn, ^max}} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
      assert Stages.get(ctx.tenant_id, ctx.story_id).escalation_reason =~ "base_churn"
    end

    test "TC-45.5.9 a base that moved after the allow is never squashed onto; the base update runs",
         ctx do
      test_pid = self()
      stub_base_update(ctx, test_pid)
      MergeForge.stub_base_head(@moved_base, ctx.branch)

      # Even a checkpoint that CONTAINS the new base head is not squashed onto it: the judged
      # diff was relative to the allow's `base_sha`, and only that base is fresh.
      MergeForge.stub_ancestors(%{{@base_head, @head} => true, {@moved_base, @head} => true})

      Mox.stub(MockMergeForge, :create_commit, fn _session, _commit ->
        send(test_pid, :squashed)
        {:ok, @merge}
      end)

      assert :base_updated = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
      refute_received :squashed
      assert Stages.get(ctx.tenant_id, ctx.story_id).head_sha == @base_update
    end

    test "a base merge that conflicts goes back to implementing over base_moved", ctx do
      make_claim_live(ctx)
      MergeForge.stub_base_head(@moved_base, ctx.branch)
      Mox.stub(MockMergeForge, :merge, fn _s, _b, _h, _m -> {:error, :merge_conflict} end)

      assert {:base_moved, :merge_conflict} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :implementing
      assert row.attempts == %{"base_moved" => 1}
    end

    test "a conflict with nobody able to fix it escalates claim_not_live instead of looping",
         ctx do
      MergeForge.stub_base_head(@moved_base, ctx.branch)
      Mox.stub(MockMergeForge, :merge, fn _s, _b, _h, _m -> {:error, :merge_conflict} end)

      assert {:escalated, {:claim_not_live, :merge_conflict}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "claim_not_live"
    end

    test "a thread branch that moved off the checkpoint is not merged into; base_moved", ctx do
      make_claim_live(ctx)
      branch = ctx.branch
      other = String.duplicate("5", 40)

      Mox.stub(MockMergeForge, :branch_head, fn
        @session, "master" -> {:ok, @moved_base}
        @session, ^branch -> {:ok, other}
      end)

      Mox.stub(MockMergeForge, :create_ref, fn _s, _b, _sha -> flunk("no base update") end)

      assert {:base_moved, {:thread_branch_moved, ^other}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "a base merge whose first parent is not the checkpoint is escalated, never recorded",
         ctx do
      MergeForge.stub_base_head(@moved_base, ctx.branch)
      pushed = String.duplicate("4", 40)

      # Somebody wrote to the temporary branch between its creation and the merge.
      Mox.stub(MockMergeForge, :merge, fn _s, _temp, "master", _m ->
        {:ok, %{sha: @base_update, tree_sha: @base_update_tree, parents: [pushed, @moved_base]}}
      end)

      Mox.stub(MockMergeForge, :update_ref, fn
        @session, "master", _sha -> :ok
        _s, _branch, @base_update -> flunk("an unexpected merge never reaches the thread")
      end)

      assert {:escalated, {:base_update_unexpected, {:first_parent, ^pushed}}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert {:ok, %{latest: %{id: id}}} = Threads.claim_checkpoints(ctx.tenant_id, ctx.story_id)
      assert id == ctx.checkpoint.id
    end

    defp tenant_token_credential(ctx) do
      repo = ForgeRepo.tenant(@repo, "github_pat_merge_0001")

      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn tenant_id, @repo ->
        assert tenant_id == ctx.tenant_id
        {:ok, %Loopctl.Verification.Credential{kind: :tenant_token, repo: repo}}
      end)

      repo
    end

    test "#936: a tenant's own token never licenses the App, and the App is never asked",
         ctx do
      tenant_token_credential(ctx)
      Mox.stub(MockMergeForge, :session, fn _repo -> flunk("the App opened a session") end)

      assert {:escalated, :app_not_licensed} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "#936: no credential for the pair escalates, and the App is never asked", ctx do
      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      Mox.stub(MockMergeForge, :session, fn _repo -> flunk("the App opened a session") end)

      assert {:escalated, :credential_unavailable} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "TC-45.5.4 without the App's credentials it escalates app_unconfigured and merges nothing",
         ctx do
      Mox.stub(MockMergeForge, :session, fn @repo -> {:error, :app_unconfigured} end)

      Mox.stub(MockMergeForge, :update_ref, fn _s, _b, _sha ->
        flunk("no merge without the App")
      end)

      assert {:escalated, :app_unconfigured} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "merge_executor: :app_unconfigured"
    end

    test "TC-45.5.5 with no allow, or an allow on another checkpoint, nothing merges", ctx do
      Mox.stub(MockMergeForge, :session, fn _repo -> flunk("no forge call without an allow") end)

      reset_allow(ctx)
      assert {:skipped, :no_allow} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      # An allow recorded for ANOTHER checkpoint: the judged head is not what it names.
      other =
        fixture(:thread_checkpoint, %{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story_id,
          seq: 2,
          commit_sha: @base,
          claim_epoch: 0
        })

      reset_allow(ctx)
      MergeForge.record_thread_allow(ctx, other, @head)

      assert {:skipped, :allow_not_for_checkpoint} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "finding 3: an allow at ci that the executor cannot resolve escalates, never skips",
         ctx do
      Mox.stub(MockMergeForge, :session, fn _repo -> flunk("no forge call") end)

      # An allow whose event names no checkpoint (a pull-request-shaped allow on a thread).
      reset_allow(ctx)

      {:ok, _row} =
        Stages.record_effect(ctx.tenant_id, ctx.story_id, :merge_gate_allowed_sha, @head,
          claim_epoch: 0
        )

      assert {:escalated, :allow_names_no_checkpoint} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "TC-45.5.6 a forge tree that is not the recorded tree escalates tree_mismatch, no ref update",
         ctx do
      forge_tree = String.duplicate("3", 40)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head -> {:ok, %{sha: @head, tree_sha: forge_tree, parents: [@base_head]}}
      end)

      Mox.stub(MockMergeForge, :create_commit, fn _s, _c -> flunk("no squash of a mismatch") end)
      Mox.stub(MockMergeForge, :update_ref, fn _s, _b, _sha -> flunk("no ref update") end)

      assert {:escalated, {:tree_mismatch, ^forge_tree, @tree}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert Stages.get(ctx.tenant_id, ctx.story_id).escalation_reason =~ "tree_mismatch"
    end

    test "a checkpoint whose tree is the base's escalates empty_change, never merged", ctx do
      Mox.stub(MockMergeForge, :commit, fn
        @session, @head -> {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}
        @session, @base_head -> {:ok, %{sha: @base_head, tree_sha: @tree, parents: []}}
      end)

      Mox.stub(MockMergeForge, :create_commit, fn _s, _c -> flunk("no squash of nothing") end)

      assert {:escalated, {:empty_change, @tree}} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end

    test "finding 2: a transient fault retries, and the last attempt escalates retries_exhausted",
         ctx do
      Mox.stub(MockMergeForge, :branch_head, fn _s, _b -> {:error, {:github_api_error, 503}} end)

      assert {:retry, {:github_api_error, 503}} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci

      job = %Oban.Job{
        args: %{"tenant_id" => ctx.tenant_id, "story_id" => ctx.story_id},
        attempt: 1,
        max_attempts: 8
      }

      assert {:error, {:github_api_error, 503}} = ThreadMergeWorker.perform(job)

      assert :ok = ThreadMergeWorker.perform(%{job | attempt: 8})

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "retries_exhausted"
    end

    test "round 2, finding 6: an exit re-exits for Oban, and on the last attempt escalates",
         ctx do
      Mox.stub(MockMergeForge, :session, fn _repo -> exit(:forge_pool_down) end)

      assert catch_exit(MergeExecutor.run(ctx.tenant_id, ctx.story_id)) == :forge_pool_down

      assert {:escalated, {:retries_exhausted, {:exited, :forge_pool_down}}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id, true)
    end

    test "round 2, finding 6: the sweep re-drives a thread story at ci with an allow", ctx do
      Mox.stub(MockMergeForge, :session, fn @repo -> {:error, :app_unconfigured} end)

      assert {ctx.tenant_id, ctx.story_id} in sweep_candidates()
      assert :ok = ThreadMergeSweepWorker.perform(%Oban.Job{})

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "app_unconfigured"

      # Off `ci`, it is no longer a candidate.
      refute {ctx.tenant_id, ctx.story_id} in sweep_candidates()
    end

    test "round 3, finding 3: a story whose current claim was placed in pr mode is never swept",
         ctx do
      assert {ctx.tenant_id, ctx.story_id} in sweep_candidates()

      set_mode(ctx, "pr")
      refute {ctx.tenant_id, ctx.story_id} in sweep_candidates()

      # A thread row of an ENDED claim does not make the current claim a thread claim.
      set_dispatch(ctx, mode: "thread", claim_epoch: 7)
      refute {ctx.tenant_id, ctx.story_id} in sweep_candidates()
    end

    test "round 2, finding 7: a squash recorded on a row past merged raises no alarm", ctx do
      set_merge_commit(ctx, @merge)

      {1, _} =
        from(r in StoryStage, where: r.story_id == ^ctx.story_id)
        |> AdminRepo.update_all(set: [stage: :deployed, merge_sha: @merge])

      MergeForge.stub_ancestors(%{{@merge, @base_head} => true})

      assert {:skipped, {:not_at_ci, :deployed}} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :deployed
    end

    test "root cause: a run whose allow changed under it asks to run again, and the worker snoozes",
         ctx do
      # A new checkpoint is recorded and the gate allows it while this run executes.
      Mox.stub(MockMergeForge, :session, fn @repo ->
        other =
          fixture(:thread_checkpoint, %{
            tenant_id: ctx.tenant_id,
            story_id: ctx.story_id,
            seq: 2,
            commit_sha: @base,
            claim_epoch: 0
          })

        reset_allow(ctx)
        MergeForge.record_thread_allow(ctx, other, @base)
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:rerun, {:retry, _}} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      # Unchanged since it began: no rerun.
      Mox.stub(MockMergeForge, :session, fn @repo -> {:error, {:github_unreachable, :timeout}} end)

      job = %Oban.Job{
        args: %{"tenant_id" => ctx.tenant_id, "story_id" => ctx.story_id},
        attempt: 1,
        max_attempts: 8
      }

      assert {:error, _} = ThreadMergeWorker.perform(job)

      Mox.stub(MockMergeForge, :session, fn @repo ->
        reset_allow(ctx)
        MergeForge.record_thread_allow(ctx, ctx.checkpoint, @head)
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:snooze, _seconds} = ThreadMergeWorker.perform(job)
    end

    test "round 3, finding 1: a last attempt whose squash reached the base adopts it", ctx do
      # GitHub applied the update and the answer timed out, on the last attempt.
      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge ->
        {:error, {:github_unreachable, :timeout}}
      end)

      MergeForge.stub_ancestors(%{{@merge, @base_head} => true})

      assert {:merged, @merge} = MergeExecutor.run(ctx.tenant_id, ctx.story_id, true)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :merged and row.merge_sha == @merge
    end

    test "round 3, finding 2: a last attempt that finds its squash on the base after a release escalates it",
         ctx do
      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge ->
        set_stage(ctx, :queued)
        {:error, {:github_unreachable, :timeout}}
      end)

      MergeForge.stub_ancestors(%{{@merge, @base_head} => true})

      assert {:escalated, {{:merged_not_recorded, :stale_stage}, @merge}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id, true)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ @merge
    end

    test "round 3, finding 2: nothing on the base and the story off ci — no edge, nothing escalated",
         ctx do
      Mox.stub(MockMergeForge, :session, fn @repo ->
        set_stage(ctx, :implementing)
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:skipped, {{:retries_exhausted, _}, :implementing}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id, true)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :implementing
    end

    test "round 3, finding 4: a forge that cannot read the unrecorded head escalates, never base_moved",
         ctx do
      make_claim_live(ctx)
      head = @base_update
      branch = ctx.branch
      stub_base_update(ctx, self())

      Mox.stub(MockMergeForge, :branch_head, fn
        @session, "master" -> {:ok, @moved_base}
        @session, ^branch -> {:ok, head}
      end)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @head -> {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}
        @session, ^head -> {:error, {:github_api_error, 403}}
        @session, sha -> {:ok, %{sha: sha, tree_sha: @base_tree, parents: []}}
      end)

      assert {:escalated, {:github_api_error, 403}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "finding 2: a crash re-raises for Oban, and on the last attempt escalates", ctx do
      Mox.stub(MockMergeForge, :session, fn _repo -> raise "forge client blew up" end)

      assert_raise RuntimeError, fn -> MergeExecutor.run(ctx.tenant_id, ctx.story_id) end
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci

      assert {:escalated, {:retries_exhausted, {:crashed, RuntimeError}}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id, true)
    end

    test "the gate's thread allow runs the executor (the enqueue is wired)", ctx do
      reset_allow(ctx)
      stub_thread(ctx)
      Mox.stub(MockMergeForge, :session, fn @repo -> {:error, :app_unconfigured} end)

      assert {:ok, %Verdict{decision: :allow}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "app_unconfigured"
    end

    test "finding 4: a thread already_merged verdict runs the executor, which records the merge",
         ctx do
      stub_thread(ctx)
      set_merge_commit(ctx, @merge)

      Mox.stub(MockPullRequestSource, :contains?, fn %ForgeRepo{full_name: @repo},
                                                     @merge,
                                                     "master" ->
        {:ok, true}
      end)

      MergeForge.stub_ancestors(%{{@merge, @base_head} => true})

      assert {:ok, %Verdict{decision: :already_merged, merge_sha: @merge}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :merged and row.merge_sha == @merge
    end

    test "TC-45.5.8 after a base update the gate allows the new head with no new review round, and it merges",
         ctx do
      test_pid = self()
      base_update_to_ci(ctx)

      # CI ran green on the base update's exact sha; the base has not moved again.
      stub_thread(ctx, head: @base_update, tree: @base_update_tree, merge_base: @moved_base)
      MergeForge.stub_base_head(@moved_base, ctx.branch)

      Mox.stub(MockMergeForge, :commit, fn
        @session, @base_update ->
          {:ok, %{sha: @base_update, tree_sha: @base_update_tree, parents: [@head, @moved_base]}}

        @session, @moved_base ->
          {:ok, %{sha: @moved_base, tree_sha: @base_tree, parents: []}}
      end)

      MergeForge.stub_ancestors(%{{@moved_base, @base_update} => true})

      Mox.stub(MockMergeForge, :create_commit, fn @session, commit ->
        send(test_pid, {:created, commit})
        {:ok, @merge}
      end)

      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge -> :ok end)

      # The allow records the base update as the checkpoint, and the executor (run inline by
      # the enqueue) squashes ITS tree onto the moved base.
      assert {:ok, %Verdict{decision: :allow} = verdict} = enforce(ctx)
      assert verdict.checkpoint_sha == @base_update
      assert allow_event_data(ctx)["payload"]["base_sha"] == @moved_base

      assert_received {:created, %{tree: @base_update_tree, parents: [@moved_base]}}

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :merged and row.merge_sha == @merge
      assert AdminRepo.get!(Story, ctx.story_id).verified_status == :verified
    end

    test "a base update is not allowed until CI on its exact sha is green (AC-45.5.7)", ctx do
      base_update_to_ci(ctx)
      Mox.stub(MockMergeForge, :session, fn _repo -> flunk("nothing to merge") end)

      stub_thread(ctx,
        head: @base_update,
        tree: @base_update_tree,
        merge_base: @moved_base,
        ci: %{jobs: [ci_run("test", "failure")], statuses: []}
      )

      assert {:ok, %Verdict{decision: :refuse} = refused} = enforce(ctx)
      assert {:required_check_failed, "test", "failure"} in refused.reasons
      assert is_nil(Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_allowed_sha)
    end
  end

  # The claim's thread-mode dispatch and first checkpoint (`fixture(:thread_claim)`). The
  # executor's own behaviour is the `merge executor (US-45.5)` block above.
  defp thread_setup(ctx) do
    {_raw_key, runner} = fixture(:runner, %{tenant_id: ctx.tenant_id})
    MergeForge.stub_app_unreachable()

    fixture(:thread_claim, %{
      tenant_id: ctx.tenant_id,
      story_id: ctx.story_id,
      runner_id: runner.id,
      commit_sha: @head,
      tree_sha: @tree
    })
  end

  # The executor's refused fast-forward, then GitHub's clean merge of the moved base into the
  # checkpoint: the story is at `ci` on the base update, its allow cleared.
  defp base_update_to_ci(ctx) do
    stub_base_update(ctx, self())
    assert :base_updated = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    Mox.stub(MockMergeForge, :merge, fn _s, _b, _h, _m -> flunk("no second base merge") end)
  end

  # A base update that succeeds: the squash's ref update is not a fast-forward, a temporary
  # branch at the checkpoint takes GitHub's clean merge of the moved base, the thread branch
  # fast-forwards to it. Each step reports to `test_pid`.
  defp stub_base_update(ctx, test_pid) do
    branch = ctx.branch

    Mox.stub(MockMergeForge, :create_ref, fn @session,
                                             "loop/loopctl-base-update-" <> _ = temp,
                                             sha ->
      send(test_pid, {:temp_created, temp, sha})
      :ok
    end)

    Mox.stub(MockMergeForge, :merge, fn @session, temp, "master", _m ->
      send(test_pid, {:merged_into, temp})
      {:ok, %{sha: @base_update, tree_sha: @base_update_tree, parents: [@head, @moved_base]}}
    end)

    Mox.stub(MockMergeForge, :update_ref, fn
      @session, "master", @merge ->
        {:error, :not_fast_forward}

      @session, ^branch, @base_update ->
        send(test_pid, {:thread_moved, @base_update})
        :ok
    end)

    Mox.stub(MockMergeForge, :delete_ref, fn @session, temp ->
      send(test_pid, {:temp_deleted, temp})
      :ok
    end)
  end

  defp stub_flunk(call, 2),
    do:
      Mox.stub(MockPullRequestSource, call, fn _a, _b ->
        flunk("#{call} read with no credential")
      end)

  defp stub_flunk(call, 3),
    do:
      Mox.stub(MockPullRequestSource, call, fn _a, _b, _c ->
        flunk("#{call} read with no credential")
      end)

  defp merge_commit(ctx) do
    AdminRepo.get!(Loopctl.Threads.Checkpoint, ctx.checkpoint.id).merge_commit_sha
  end

  defp sweep_candidates do
    ThreadMergeSweepWorker.candidates_query()
    |> Ecto.Query.exclude(:limit)
    |> AdminRepo.all()
  end

  defp set_stage(ctx, stage) do
    {1, _} =
      from(r in StoryStage, where: r.story_id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [stage: stage])
  end

  defp set_head(ctx, sha) do
    {1, _} =
      from(r in StoryStage, where: r.story_id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [head_sha: sha])
  end

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

    Mox.stub(MockPullRequestSource, :branch_head, fn %ForgeRepo{full_name: @repo}, ^branch ->
      {:ok, Keyword.get(opts, :branch_head, head)}
    end)

    Mox.stub(MockPullRequestSource, :commit, fn %ForgeRepo{full_name: @repo}, ^head ->
      {:ok,
       %{
         tree_sha: Keyword.get(opts, :tree, @tree)
       }}
    end)

    base_branch = Keyword.get(opts, :base_branch, "master")

    Mox.stub(MockPullRequestSource, :compare, fn %ForgeRepo{full_name: @repo},
                                                 ^base_branch,
                                                 ^head ->
      {:ok, comparison(Keyword.get(opts, :base_tree, @base_tree), opts)}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
      {:ok, @repo_files}
    end)

    # US-45.6: CI on the CHECKPOINT's commit, green unless the test says otherwise.
    ci = Keyword.get(opts, :ci, %{jobs: [ci_run("test", "success")], statuses: []})
    # The read names the thread branch: only its push runs are trusted.
    Mox.stub(MockPullRequestSource, :check_evidence, fn %ForgeRepo{full_name: @repo},
                                                        ^head,
                                                        ^branch ->
      {:ok, ci}
    end)
  end

  # Records the story's transition into `ci` at `at` (the CI wait's origin).
  defp enter_ci_at(ctx, at) do
    AdminRepo.insert!(%Loopctl.Delivery.StageEvent{
      tenant_id: ctx.tenant_id,
      story_stage_id: Stages.get(ctx.tenant_id, ctx.story_id).id,
      story_id: ctx.story_id,
      event: "transitioned",
      from_stage: "pr_open",
      to_stage: "ci",
      edge: "forward",
      claim_epoch: 0,
      lock_version: 0,
      data: %{},
      inserted_at: at
    })
  end

  defp checkpoint_evidence(ctx) do
    AdminRepo.get!(Loopctl.Threads.Checkpoint, ctx.checkpoint.id).gate_evidence
  end

  # A refusal test after an allow: the recorded allow is for the same head, and the story is
  # back at `ci` with nothing allowed so the gate judges afresh.
  defp reset_allow(ctx) do
    {1, _} =
      from(r in StoryStage, where: r.story_id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [merge_gate_allowed_sha: nil])
  end

  defp ci_run(name, conclusion, status \\ "completed"),
    do: %{name: name, status: status, conclusion: conclusion, url: nil, app: "github-actions"}

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
    Mox.stub(MockPullRequestSource, :branch_head, fn %ForgeRepo{full_name: @repo}, _branch ->
      {:error, {:github_api_error, 404}}
    end)

    Mox.stub(MockPullRequestSource, :repository_readable, fn %ForgeRepo{full_name: @repo} ->
      :ok
    end)
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

    Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _number ->
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

    Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
      {:ok, @repo_files}
    end)
  end

  defp stub_unreachable do
    Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _number ->
      {:error, {:github_unreachable, :timeout}}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
      {:error, {:github_unreachable, :timeout}}
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

    Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
      {:ok, @repo_files}
    end)
  end
end
