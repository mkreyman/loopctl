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

    test "an ALLOW that cannot be recorded becomes a refusal", ctx do
      # A stale epoch cannot write, and an allow nobody recorded is an allow nobody can
      # later account for — so it must not stand.
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1})

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} =
               MergePrecondition.enforce(
                 ctx.tenant_id,
                 ctx.story_id,
                 Keyword.put(opts(), :claim_epoch, 99)
               )

      assert {:allow_not_recorded, :stale_claim_epoch} in reasons
      assert is_nil(Stages.get(ctx.tenant_id, ctx.story_id).merge_gate_allowed_sha)
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

    test "a TRANSIENT forge fault transitions nothing", ctx do
      Mox.stub(MockPullRequestSource, :pull_request, fn _repo, _n ->
        {:error, {:github_unreachable, :timeout}}
      end)

      assert {:ok, %Verdict{decision: :unevaluated, reasons: reasons}} = enforce(ctx)
      assert {:pull_request_unavailable, {:github_unreachable, :timeout}} in reasons

      # One blip must not park a story on a human: `escalated` is human-only.
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
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
      trio_outputs: List.duplicate(trio(), 3),
      actor_label: "test",
      # Entering `escalated` is a CHAINED transition, and `Stages.advance/4` refuses one
      # that does not declare the actor's lineage. An operator key legitimately has none.
      actor_lineage: []
    ]
  end

  defp trio do
    %{
      "verdict" => "story",
      "escalation_reasons" => [],
      "contradicts" => [],
      "confidence" => 0.9
    }
  end

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
