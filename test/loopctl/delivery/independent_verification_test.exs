defmodule Loopctl.Delivery.IndependentVerificationTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition.independent_verification/3` (US-52.12) against real
  rows: the story's recorded custody at the head, the `runner_dispatches` ledger with its
  `runners.name`, and the repository's `independent_checks` judged over the forge's CI
  evidence. Then `evaluate/3`, to prove `gather/4` resolves the fact only where a decision
  consumes it.

  The trigger document is `config/test.exs`'s: `acme/widgets`, independent path
  `lib/widgets_web/router.ex`, independent check `e2e`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.WorkBreakdown.Story

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @branch "loop/us-52-12"
  @repo_files ["priv/rates/2026.csv", "lib/widgets_web/router.ex", "lib/widgets/thing.ex"]

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})

    ctx =
      fixture(:merge_ready_story, %{
        tenant_id: tenant.id,
        repo: @repo,
        head_sha: @head,
        branch: @branch
      })

    # The pull request fact 3 reads for its CI-definition refusal; a test that needs another
    # diff stubs its own.
    stub_pull_request(["lib/widgets/thing.ex"])

    Map.merge(ctx, %{
      implementer_runner: fixture(:stage_runner, %{tenant_id: tenant.id}),
      verifier_runner: fixture(:stage_runner, %{tenant_id: tenant.id})
    })
  end

  describe "TC-52.12.3: a separated verifier at the head, on another machine" do
    test "is :ok with every independent check green at the head", ctx do
      attest(ctx)
      stub_checks(ctx, [job("e2e", "success")])

      assert verification(ctx) == :ok
      assert_received {:checks_read, @head, @branch}
    end

    test "a story whose custody does not pass at the head is not independently verified",
         ctx do
      attest(ctx)
      stub_checks(ctx, [job("e2e", "success")])

      set_stage(ctx, verified_head_sha: String.duplicate("c", 40))
      assert verification(ctx) == {:error, :not_independently_verified}

      set_stage(ctx, verified_head_sha: @head)
      update_story(ctx, verified_status: :unverified)
      assert verification(ctx) == {:error, :not_independently_verified}
    end

    test "a verifier lineage sharing the implementer's root is refused by merge_custody_status",
         ctx do
      # The lineage comparison is `verify_lineage_separated/4`'s, reached through
      # `merge_custody_status/1`; nothing here compares lineages a second time.
      attest(ctx)
      stub_checks(ctx, [job("e2e", "success")])
      story = AdminRepo.get!(Story, ctx.story_id)
      update_story(ctx, verifier_dispatch_id: story.implementer_dispatch_id)
      attest_verifier(ctx, ctx.verifier_runner, story.implementer_dispatch_id)

      assert verification(ctx) == {:error, :not_independently_verified}
    end

    test "a verifier that ran on an implementer's machine is :same_host", ctx do
      attest_implementer(ctx, ctx.implementer_runner)
      attest_verifier(ctx, ctx.implementer_runner)
      stub_checks(ctx, [job("e2e", "success")])

      assert verification(ctx) == {:error, :same_host}
    end

    test "EVERY implementer machine counts, not only the latest", ctx do
      attest_implementer(ctx, ctx.implementer_runner, claim_epoch: 0)
      attest_implementer(ctx, ctx.verifier_runner, claim_epoch: 1)
      attest_verifier(ctx, ctx.verifier_runner)
      stub_checks(ctx, [job("e2e", "success")])

      assert verification(ctx) == {:error, :same_host}
    end

    test "a missing ledger row on either side is :host_unattested", ctx do
      stub_checks(ctx, [job("e2e", "success")])

      attest_verifier(ctx, ctx.verifier_runner)
      assert verification(ctx) == {:error, :host_unattested}

      attest_implementer(ctx, ctx.implementer_runner)
      assert verification(ctx) == :ok
    end

    test "a verify row for ANOTHER dispatch, or one never accepted, attests nothing", ctx do
      attest_implementer(ctx, ctx.implementer_runner)
      stub_checks(ctx, [job("e2e", "success")])

      attest_verifier(ctx, ctx.verifier_runner, Ecto.UUID.generate())
      assert verification(ctx) == {:error, :host_unattested}

      story = AdminRepo.get!(Story, ctx.story_id)

      fixture(:accepted_dispatch, %{
        tenant_id: ctx.tenant_id,
        runner: ctx.verifier_runner,
        story_id: ctx.story_id,
        kind: "verify",
        status: "sent",
        dispatch_id: story.verifier_dispatch_id
      })

      assert verification(ctx) == {:error, :host_unattested}
    end
  end

  describe "TC-52.12.4: every independent check passed at the head" do
    test "a failed, pending or missing check is named", ctx do
      attest(ctx)

      for jobs <- [
            [job("e2e", "failure")],
            [%{job("e2e", nil) | status: "in_progress"}],
            [job("test", "success")]
          ] do
        stub_checks(ctx, jobs)

        assert verification(ctx) == {:error, {:independent_checks_not_passed, ["e2e"]}},
               inspect(jobs)
      end
    end

    test "a required check passing does not stand in for the independent one", ctx do
      # The intake source requires `test`; the trigger document requires `e2e`. Only the
      # document's list is judged here.
      attest(ctx)
      stub_checks(ctx, [job("test", "success"), job("e2e", "skipped")])

      assert verification(ctx) == {:error, {:independent_checks_not_passed, ["e2e"]}}
    end

    test "a change to its own CI definitions is refused before the checks are read", ctx do
      attest(ctx)

      Mox.stub(MockPullRequestSource, :check_evidence, fn _repo, _sha, _branch ->
        flunk("checks were read for a change that edits the definitions they run")
      end)

      for touched <- [
            ".github/workflows/x.yml",
            ".github/actions/setup/action.yml",
            ".github/scripts/changed-areas.sh"
          ] do
        stub_pull_request(["lib/widgets/thing.ex", touched])

        assert verification(ctx) == {:error, {:ci_definition_changed, [touched]}}, touched
      end
    end

    test "a diff that could not be listed, or no diff at all, is refused", ctx do
      attest(ctx)
      stub_checks(ctx, [job("e2e", "success")])

      truncated = {:ok, %{diff: {:error, :truncated}}}

      assert verification(ctx, pull_request: truncated) ==
               {:error, {:ci_definition_unknown, :truncated}}

      assert verification(ctx, pull_request: {:ok, %{state: "open"}}) ==
               {:error, {:ci_definition_unknown, :no_diff}}

      assert verification(ctx, pull_request: {:error, {:github_unreachable, :timeout}}) ==
               {:error, {:github_unreachable, :timeout}}
    end

    test "the forge's error is passed through for transient?/1 to classify", ctx do
      attest(ctx)

      Mox.stub(MockPullRequestSource, :check_evidence, fn _repo, _sha, _branch ->
        {:error, {:github_rate_limited, 429, 30}}
      end)

      assert verification(ctx) == {:error, {:github_rate_limited, 429, 30}}
    end

    test "no recorded branch, no credential, or no configured checks refuses", ctx do
      attest(ctx)
      stub_checks(ctx, [job("e2e", "success")])

      set_stage(ctx, branch: nil)
      assert verification(ctx) == {:error, :branch_not_recorded}
      set_stage(ctx, branch: @branch)

      assert verification(ctx, repo: {:ok, "acme/other"}) ==
               {:error, :independent_checks_unconfigured}

      assert verification(ctx, triggers: {:error, :missing_config}) ==
               {:error, :independent_checks_unconfigured}

      assert verification(ctx, repo: {:error, :no_intake_source}) ==
               {:error, {:repository_unresolved, :no_intake_source}}

      Mox.stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        {:error, :credential_unavailable}
      end)

      assert verification(ctx) == {:error, :credential_unavailable}
    end
  end

  describe "tenant isolation" do
    test "another tenant's story, or another tenant's ledger, verifies nothing", ctx do
      attest(ctx)
      stub_checks(ctx, [job("e2e", "success")])
      other = fixture(:tenant, %{trust_tier: :agent_rooted})
      story = AdminRepo.get!(Story, ctx.story_id)

      assert MergePrecondition.independent_verification(other.id, story) ==
               {:error, :not_independently_verified}

      # The other tenant's ledger is invisible to this story's tenant: hosts read under RLS
      # AND an explicit tenant predicate.
      other_ctx =
        fixture(:merge_ready_story, %{
          tenant_id: other.id,
          repo: "acme/isolation-#{System.unique_integer([:positive])}",
          head_sha: @head,
          branch: @branch
        })

      assert %{implementers: [], verifier: []} =
               DispatchLedger.story_hosts(
                 other.id,
                 ctx.story_id,
                 story.verifier_dispatch_id
               )

      assert %{implementers: [], verifier: []} =
               DispatchLedger.story_hosts(
                 ctx.tenant_id,
                 other_ctx.story_id,
                 story.verifier_dispatch_id
               )
    end
  end

  describe "gather/4 resolves the fact only where the decision consumes it" do
    test "an independent path merges only once independently verified", ctx do
      stub_pull_request(["lib/widgets_web/router.ex"])
      stub_checks(ctx, [job("e2e", "success")])

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} = evaluate(ctx)
      assert {:independent_verification, :host_unattested} in reasons

      attest(ctx)
      assert {:ok, %Verdict{decision: :allow}} = evaluate(ctx)
    end

    test "a change with no independent reason never reads the checks", ctx do
      stub_pull_request(["lib/widgets/thing.ex"])

      Mox.stub(MockPullRequestSource, :check_evidence, fn _repo, _sha, _branch ->
        flunk("independent checks were read for a change that needs none")
      end)

      assert {:ok, %Verdict{decision: :allow}} = evaluate(ctx)
    end

    test "TC-52.12.6: a control-plane repository holds a clean change for verification", ctx do
      stub_pull_request(["lib/widgets/thing.ex"])
      stub_checks(ctx, [job("e2e", "success")])

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} =
               evaluate(ctx, control_plane_repos: [String.upcase(@repo)])

      assert {:independent_path, :control_plane, @repo} in reasons
      assert {:independent_verification, :host_unattested} in reasons

      attest(ctx)

      assert {:ok, %Verdict{decision: :allow}} =
               evaluate(ctx, control_plane_repos: [@repo])
    end

    test "a control-plane change that edits its own workflow is held", ctx do
      stub_pull_request(["lib/widgets/thing.ex", ".github/workflows/x.yml"])
      stub_checks(ctx, [job("e2e", "success")])
      attest(ctx)

      assert {:ok, %Verdict{decision: :refuse, reasons: reasons}} =
               evaluate(ctx, control_plane_repos: [@repo])

      assert {:independent_verification, {:ci_definition_changed, [".github/workflows/x.yml"]}} in reasons
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp verification(ctx, opts \\ []) do
    story = AdminRepo.get!(Story, ctx.story_id)
    MergePrecondition.independent_verification(ctx.tenant_id, story, opts)
  end

  defp evaluate(ctx, opts \\ []) do
    MergePrecondition.evaluate(
      ctx.tenant_id,
      ctx.story_id,
      [claim_epoch: 0, actor_label: "test", actor_lineage: []] ++ opts
    )
  end

  defp attest(ctx) do
    attest_implementer(ctx, ctx.implementer_runner)
    attest_verifier(ctx, ctx.verifier_runner)
  end

  defp attest_implementer(ctx, runner, opts \\ []) do
    fixture(:accepted_dispatch, %{
      tenant_id: ctx.tenant_id,
      runner: runner,
      story_id: ctx.story_id,
      claim_epoch: Keyword.get(opts, :claim_epoch, 0)
    })
  end

  defp attest_verifier(ctx, runner, dispatch_id \\ nil) do
    dispatch_id = dispatch_id || AdminRepo.get!(Story, ctx.story_id).verifier_dispatch_id

    fixture(:accepted_dispatch, %{
      tenant_id: ctx.tenant_id,
      runner: runner,
      story_id: ctx.story_id,
      kind: "verify",
      dispatch_id: dispatch_id
    })
  end

  defp stub_checks(_ctx, jobs) do
    test_pid = self()

    Mox.stub(MockPullRequestSource, :check_evidence, fn %ForgeRepo{full_name: @repo},
                                                        sha,
                                                        branch ->
      send(test_pid, {:checks_read, sha, branch})
      {:ok, %{jobs: jobs, statuses: []}}
    end)
  end

  defp job(name, conclusion) do
    %{
      name: name,
      status: "completed",
      conclusion: conclusion,
      id: System.unique_integer([:positive]),
      run_id: 1,
      workflow: ".github/workflows/ci.yml"
    }
  end

  defp stub_pull_request(files) do
    Mox.stub(MockPullRequestSource, :pull_request, fn %ForgeRepo{full_name: @repo}, _number ->
      {:ok,
       %{
         state: "open",
         merged?: false,
         merge_sha: nil,
         head_sha: @head,
         merge_base_sha: @base,
         diffstat: %{files: length(files), changed_lines: 3},
         diff: {:ok, %{files: files, renames: []}}
       }}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn %ForgeRepo{full_name: @repo}, _ref ->
      {:ok, @repo_files}
    end)
  end

  defp set_stage(ctx, changes) do
    {1, _} =
      from(s in StoryStage, where: s.story_id == ^ctx.story_id)
      |> AdminRepo.update_all(set: changes)
  end

  defp update_story(ctx, changes) do
    {1, _} =
      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(set: changes)
  end
end
