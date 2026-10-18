defmodule Loopctl.Delivery.MergePreconditionIntegrationTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition.evaluate/3` and `enforce/3` end to end (issue #803).

  The precondition reads the story, the intake source and the dispatch lineage on
  `AdminRepo` (as `Loopctl.Progress`, `Loopctl.Intake` and `Loopctl.Dispatches` all do) and
  the stage row on `Loopctl.Repo` (as `Loopctl.Delivery.Stages` does, and it is the only
  writer of that table). AdminRepo runs on Repo's sandbox connection in test
  (`Loopctl.AdminRepo.Route`), so both see this test's own rows and nothing here commits.

  The whole decision without the database is `Loopctl.Delivery.MergePreconditionJudgeTest`, and the custody clause is
  `Loopctl.Progress.MergeCustodyStatusTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Delivery.GateAInput
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
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
