defmodule Loopctl.Changes.TrunkEvidenceTest do
  @moduledoc """
  US-47.6: a chg story's CI-evidence input on every verify path (Epic 47 PRD §7) — its
  landing's TRUNK commit (`data.merge_sha`) must be in `verified/master`, asked of the forge by
  sha, and no applied `reverted` may follow the landing. The forge is the Mox
  `Loopctl.MockPullRequestSource` (`contains?/3`, fail-closed by default in DataCase). The HTTP
  surface is `LoopctlWeb.ChgTrunkVerificationControllerTest`'s.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.BulkOperations
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Changes.TrunkEvidence
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Dispatches
  alias Loopctl.MockPullRequestSource
  alias Loopctl.MockVerificationCredential
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @repo "mkreyman/infra"

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    tenant_id = source.tenant_id

    impl_agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: impl_agent.id})

    epic = fixture(:epic, %{tenant_id: tenant_id})

    %{
      tenant_id: tenant_id,
      secret: secret,
      source: source,
      root: root,
      impl: impl,
      impl_agent: impl_agent,
      epic: epic,
      story: reported_done(tenant_id, epic, impl_agent, impl)
    }
  end

  defp reported_done(tenant_id, epic, impl_agent, impl) do
    fixture(:story, %{tenant_id: tenant_id, epic_id: epic.id})
    |> Ecto.Changeset.change(%{
      agent_status: :reported_done,
      reported_done_at: DateTime.add(DateTime.utc_now(), -60, :second),
      assigned_agent_id: impl_agent.id,
      implementer_dispatch_id: impl.id
    })
    |> AdminRepo.update!()
  end

  defp sha(char), do: String.duplicate(char, 40)

  defp push!(ctx, change_id, seq, kind, attrs) do
    raw =
      Jason.encode!(
        build(:chg_event, Map.merge(%{change_id: change_id, event_seq: seq, kind: kind}, attrs))
      )

    ts = Integer.to_string(System.os_time(:second))

    assert {:ok, %{outcome: :applied}} =
             Events.receive_push(ctx.source.id, %{
               raw_body: raw,
               timestamp: ts,
               signature: Signature.header(ctx.secret, Signature.delivery_string(ts, raw))
             })

    :ok
  end

  # Submitted as revision `rev_sha`, landed onto trunk as `merge_sha`, and reviewed by a chg
  # child naming the landed revision: everything US-47.5 asks, so the trunk evidence is the
  # only thing left between the story and `verified`. No stage row, so nothing escalates.
  defp landed_and_reviewed(ctx, story, change_id, rev_sha, merge_sha) do
    :ok = push!(ctx, change_id, 1, "submitted", %{sha: rev_sha, data: %{"story_id" => story.id}})
    :ok = push!(ctx, change_id, 2, "landed", %{sha: rev_sha, data: %{"merge_sha" => merge_sha}})
    review_landed!(ctx, story, rev_sha)
    story
  end

  defp review_landed!(ctx, story, rev_sha) do
    child = fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id, parent: ctx.root})

    assert {:ok, _} =
             Progress.record_review(
               ctx.tenant_id,
               story.id,
               %{"review_type" => "chg", "summary" => "chg review", "commit_sha" => rev_sha},
               reviewer_agent_id: fixture(:agent, %{tenant_id: ctx.tenant_id}).id,
               reviewer_lineage: child.lineage_path
             )
  end

  # A never-dispatched story imported at `reported_done` — the one shape backfill and bulk
  # mark-complete accept — bound and landed. Its chg review is written directly: review-complete
  # refuses a custody-orphaned story, so on these paths the trunk gate is defence in depth
  # behind US-47.5's, and this is how it is reached at all.
  defp backfillable_landed(ctx, change_id, rev_sha, merge_sha) do
    story =
      fixture(:story, %{tenant_id: ctx.tenant_id, epic_id: ctx.epic.id})
      |> Ecto.Changeset.change(%{agent_status: :reported_done})
      |> AdminRepo.update!()

    :ok = push!(ctx, change_id, 1, "submitted", %{sha: rev_sha, data: %{"story_id" => story.id}})
    :ok = push!(ctx, change_id, 2, "landed", %{sha: rev_sha, data: %{"merge_sha" => merge_sha}})

    fixture(:review_record, %{
      tenant_id: ctx.tenant_id,
      story_id: story.id,
      commit_sha: rev_sha,
      reviewer_dispatch_id:
        fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id, parent: ctx.root}).id
    })

    AdminRepo.get!(Story, story.id)
  end

  defp outsider(ctx) do
    agent = fn -> fixture(:agent, %{tenant_id: ctx.tenant_id}).id end

    {:ok, %{dispatch: other_root}} =
      Dispatches.create_dispatch(ctx.tenant_id, %{role: :orchestrator, agent_id: agent.()})

    {:ok, %{dispatch: other}} =
      Dispatches.create_dispatch(ctx.tenant_id, %{
        role: :orchestrator,
        agent_id: agent.(),
        parent_dispatch_id: other_root.id
      })

    other
  end

  defp verifier_opts(ctx) do
    other = outsider(ctx)
    [orchestrator_agent_id: other.agent_id, verifier_lineage: other.lineage_path]
  end

  defp verify(ctx, story),
    do: Progress.verify_story(ctx.tenant_id, story.id, %{}, verifier_opts(ctx))

  # The forge's answer for `merge_sha` against `verified/master`, asserting the call names the
  # TRUNK commit and the ref — never the revision commit — and runs outside every transaction.
  # On a batch path the call runs in a `Task.async_stream` worker, which never joins its
  # caller's transaction, so `in_transaction?/0` there proves nothing: the check reads the
  # transaction state of the calling process AND of every process it was started for.
  defp forge(merge_sha, answer, times \\ 1) do
    expect(MockPullRequestSource, :contains?, times, fn %ForgeRepo{full_name: @repo},
                                                        ^merge_sha,
                                                        "verified/master" ->
      refute any_caller_in_transaction?()
      answer
    end)
  end

  # Ecto keeps a process's checked-out connection under `{Ecto.Adapters.SQL, pool}` in that
  # process's dictionary, with `conn_mode: :transaction` while a transaction is open — the
  # same read `Repo.in_transaction?/0` makes, here made on another process too.
  defp any_caller_in_transaction? do
    Enum.any?([self() | Process.get(:"$callers", [])], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          Enum.any?(
            dict,
            &match?({{Ecto.Adapters.SQL, _}, %DBConnection{conn_mode: :transaction}}, &1)
          )

        nil ->
          false
      end
    end)
  end

  defp no_forge_call, do: expect(MockPullRequestSource, :contains?, 0, fn _, _, _ -> :unused end)

  defp unverified!(story),
    do: assert(AdminRepo.get!(Story, story.id).verified_status == :unverified)

  describe "AC-47.6.1: the landing's trunk commit must be in verified/master" do
    test "an ancestor (or the same commit) verifies; the forge is asked about merge_sha", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      forge(sha("c"), {:ok, true})

      assert {:ok, %Story{verified_status: :verified}} = verify(ctx, story)
    end

    test "TC-47.6.1: not yet in verified/master is chg_landing_not_trunk_verified", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      forge(sha("c"), {:ok, false})

      assert {:error, :chg_landing_not_trunk_verified} = verify(ctx, story)
      unverified!(story)
    end

    test "a landing naming no valid trunk commit is refused without asking the forge", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), "not-a-sha")
      no_forge_call()

      assert {:error, :chg_landing_not_trunk_verified} = verify(ctx, story)
      unverified!(story)
    end

    test "TC-47.6.2: landed, verified, then reverted is chg_landing_reverted, forge unasked",
         ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      :ok = push!(ctx, "C1", 3, "verified", %{sha: sha("a"), data: %{"sha" => sha("c")}})

      :ok =
        push!(ctx, "C1", 4, "reverted", %{
          sha: sha("a"),
          data: %{"landed_sha" => sha("c"), "revert_sha" => sha("d")}
        })

      no_forge_call()

      assert {:error, :chg_landing_reverted} = verify(ctx, story)
      unverified!(story)
    end

    test "a re-landing after the revert is a NEW landing, judged afresh", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))

      :ok =
        push!(ctx, "C1", 3, "reverted", %{sha: sha("a"), data: %{"landed_sha" => sha("c")}})

      :ok = push!(ctx, "C1", 4, "submitted", %{sha: sha("b"), data: %{"story_id" => story.id}})
      :ok = push!(ctx, "C1", 5, "landed", %{sha: sha("b"), data: %{"merge_sha" => sha("e")}})
      review_landed!(ctx, story, sha("b"))

      forge(sha("e"), {:ok, true})
      assert {:ok, %Story{verified_status: :verified}} = verify(ctx, story)
    end

    test "a local trunk_verified_sha equal to merge_sha is not taken as the answer", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      :ok = push!(ctx, "C1", 3, "verified", %{sha: sha("a"), data: %{"sha" => sha("c")}})
      forge(sha("c"), {:ok, false})

      assert {:error, :chg_landing_not_trunk_verified} = verify(ctx, story)
    end
  end

  describe "AC-47.6.2: a compare that cannot answer is unevaluated, never a pass" do
    for {name, answer, reason, retry} <- [
          {"TC-47.6.3: a timeout", {:error, {:github_unreachable, :timeout}}, "forge_unavailable",
           30},
          {"a 5xx", {:error, {:github_api_error, 502}}, "forge_unavailable", 30},
          {"a rate limit, with the forge's own delay", {:error, {:github_rate_limited, 429, 120}},
           "forge_unavailable", 120},
          {"a 404: verified/master (or the commit) does not exist yet",
           {:error, {:github_api_error, 404}}, "trunk_ref_not_found", 30},
          {"a 401", {:error, {:github_api_error, 401}}, "forge_unauthorized", 30},
          {"a permission 403", {:error, {:github_api_error, 403}}, "forge_forbidden", 30},
          {"a 422", {:error, {:github_api_error, 422}}, "forge_rejected", 30},
          {"an unreadable body", {:error, {:unreadable_compare, :x}}, "forge_unreadable", 30}
        ] do
      test "#{name} is chg_trunk_unevaluated #{reason}", ctx do
        story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
        forge(sha("c"), unquote(Macro.escape(answer)))

        assert {:error, {:chg_trunk_unevaluated, unquote(reason), unquote(retry)}} =
                 verify(ctx, story)

        unverified!(story)
      end
    end

    test "no credential for the repository waits the configuration interval, forge unasked",
         ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))

      stub(MockVerificationCredential, :for_read, fn _tenant, @repo ->
        {:error, :credential_unavailable}
      end)

      no_forge_call()

      assert {:error, {:chg_trunk_unevaluated, "credential_unavailable", 3600}} =
               verify(ctx, story)
    end

    test "an assessment made for an EARLIER landing is landing_changed, never applied", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      forge(sha("c"), {:ok, true})
      stale = TrunkEvidence.assess(ctx.tenant_id, story.id)
      assert %{outcome: :ancestor} = stale

      :ok = push!(ctx, "C1", 3, "submitted", %{sha: sha("b"), data: %{"story_id" => story.id}})
      :ok = push!(ctx, "C1", 4, "landed", %{sha: sha("b"), data: %{"merge_sha" => sha("e")}})

      assert {:error, {:chg_trunk_unevaluated, "landing_changed", 30}} =
               TrunkEvidence.ensure_trunk_verified(ctx.tenant_id, story.id, stale)

      assert {:error, {:chg_trunk_unevaluated, "landing_changed", 30}} =
               TrunkEvidence.ensure_trunk_verified(ctx.tenant_id, story.id, nil)
    end
  end

  describe "AC-47.6.3: every other gate unchanged" do
    test "a custody refusal is answered before the trunk evidence, even with the forge down",
         ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))

      stub(MockPullRequestSource, :contains?, fn _, _, _ -> {:error, {:github_api_error, 503}} end)

      assert {:error, :self_verify_blocked} =
               Progress.verify_story(ctx.tenant_id, story.id, %{},
                 orchestrator_agent_id: ctx.impl_agent.id,
                 verifier_lineage: ctx.impl.lineage_path
               )
    end

    test "the landed-review gate still comes first", ctx do
      # A review recorded off the chg path, before the binding: review_not_conducted is
      # satisfied, US-47.5's landed-review gate is not.
      off_chg = outsider(ctx)

      {:ok, _} =
        Progress.record_review(ctx.tenant_id, ctx.story.id, %{"review_type" => "enhanced"},
          reviewer_agent_id: off_chg.agent_id,
          reviewer_lineage: off_chg.lineage_path
        )

      :ok =
        push!(ctx, "C1", 1, "submitted", %{sha: sha("a"), data: %{"story_id" => ctx.story.id}})

      :ok = push!(ctx, "C1", 2, "landed", %{sha: sha("a"), data: %{"merge_sha" => sha("c")}})
      no_forge_call()

      assert {:error, :chg_review_not_for_landed_revision} = verify(ctx, ctx.story)
    end

    test "a story the local gates refuse costs no forge call, on any verify path", ctx do
      # Landed but never reviewed: review_not_conducted on verify, the landed-review gate on
      # the bulk paths. Each refusal is answered under the lock as before, unasked.
      :ok =
        push!(ctx, "C1", 1, "submitted", %{sha: sha("a"), data: %{"story_id" => ctx.story.id}})

      :ok = push!(ctx, "C1", 2, "landed", %{sha: sha("a"), data: %{"merge_sha" => sha("c")}})
      no_forge_call()
      opts = verifier_opts(ctx)

      assert {:error, :review_not_conducted} = verify(ctx, ctx.story)

      assert {:ok, %{verified_count: 0, errors: [%{reason: ":review_not_conducted"}]}} =
               Progress.verify_all_in_epic(ctx.tenant_id, ctx.epic.id, %{"summary" => "a"}, opts)

      assert {:ok, [%{status: "error"}]} =
               BulkOperations.bulk_verify(
                 ctx.tenant_id,
                 [%{"story_id" => ctx.story.id}],
                 opts[:orchestrator_agent_id],
                 opts
               )

      assert {:error, _refused} =
               Progress.backfill_story(ctx.tenant_id, ctx.story.id, %{"reason" => "pre"}, [])

      unverified!(ctx.story)
    end

    test "a story with NO change binding never asks the forge, on any path", ctx do
      no_forge_call()
      outsider = outsider(ctx)

      {:ok, _} =
        Progress.record_review(ctx.tenant_id, ctx.story.id, %{"review_type" => "enhanced"},
          reviewer_agent_id: outsider.agent_id,
          reviewer_lineage: outsider.lineage_path
        )

      assert :not_chg = TrunkEvidence.assess(ctx.tenant_id, ctx.story.id)
      assert {:ok, %Story{verified_status: :verified}} = verify(ctx, ctx.story)

      other = fixture(:story, %{tenant_id: ctx.tenant_id, epic_id: ctx.epic.id})

      assert {:ok, %Story{verified_status: :verified}} =
               Progress.backfill_story(ctx.tenant_id, other.id, %{"reason" => "pre"}, [])

      third = fixture(:story, %{tenant_id: ctx.tenant_id, epic_id: ctx.epic.id})

      assert {:ok, [%{status: "success"}]} =
               BulkOperations.bulk_mark_complete(
                 ctx.tenant_id,
                 [%{"story_id" => third.id, "summary" => "pre", "review_type" => "pre"}],
                 outsider.agent_id,
                 []
               )
    end
  end

  describe "every verify path takes the trunk gate" do
    test "verify-all and bulk verify refuse per story; a pass on the forge verifies", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      forge(sha("c"), {:ok, false}, 2)
      opts = verifier_opts(ctx)

      assert {:ok, %{verified_count: 0, errors: [%{reason: ":chg_landing_not_trunk_verified"}]}} =
               Progress.verify_all_in_epic(ctx.tenant_id, ctx.epic.id, %{"summary" => "a"}, opts)

      assert {:ok, [%{status: "error", reason: "chg_landing_not_trunk_verified: " <> _}]} =
               BulkOperations.bulk_verify(
                 ctx.tenant_id,
                 [%{"story_id" => story.id}],
                 opts[:orchestrator_agent_id],
                 opts
               )

      unverified!(story)

      forge(sha("c"), {:error, {:github_unreachable, :timeout}})

      assert {:ok, [%{status: "error", reason: "chg_trunk_unevaluated: forge_unavailable" <> _}]} =
               BulkOperations.bulk_verify(
                 ctx.tenant_id,
                 [%{"story_id" => story.id}],
                 opts[:orchestrator_agent_id],
                 opts
               )

      forge(sha("c"), {:ok, true})

      assert {:ok, [%{status: "success"}]} =
               BulkOperations.bulk_verify(
                 ctx.tenant_id,
                 [%{"story_id" => story.id}],
                 opts[:orchestrator_agent_id],
                 opts
               )
    end

    test "backfill and bulk mark-complete take the same gate", ctx do
      pending = backfillable_landed(ctx, "C2", sha("a"), sha("c"))
      forge(sha("c"), {:ok, false}, 2)

      assert {:error, :chg_landing_not_trunk_verified} =
               Progress.backfill_story(ctx.tenant_id, pending.id, %{"reason" => "pre"}, [])

      assert {:ok, [%{status: "error", reason: "chg_landing_not_trunk_verified: " <> _}]} =
               BulkOperations.bulk_mark_complete(
                 ctx.tenant_id,
                 [%{"story_id" => pending.id, "summary" => "pre", "review_type" => "pre"}],
                 Ecto.UUID.generate(),
                 []
               )

      unverified!(pending)
    end

    test "a chg story missing from a batch's assessment is never passed", ctx do
      pending = backfillable_landed(ctx, "C2", sha("a"), sha("c"))
      no_forge_call()

      assert {:error, {:chg_trunk_unevaluated, "landing_changed", 30}} =
               Progress.ensure_mark_complete_allowed(
                 pending,
                 MapSet.new(),
                 %{}
               )
    end
  end

  describe "tenant isolation" do
    test "another tenant reading this story id finds no binding and asks nothing", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      other_tenant = fixture(:tenant)
      no_forge_call()

      assert :not_chg = TrunkEvidence.assess(other_tenant.id, story.id)
      assert %{} == TrunkEvidence.assess_many(other_tenant.id, [story.id])
      assert :ok = TrunkEvidence.ensure_trunk_verified(other_tenant.id, story.id, nil)
    end

    test "another tenant's revert of the same change id reverts nothing here", ctx do
      story = landed_and_reviewed(ctx, ctx.story, "C1", sha("a"), sha("c"))
      other = fixture(:chg_source, %{})
      other_story = fixture(:story, %{tenant_id: other.source.tenant_id})
      octx = %{source: other.source, secret: other.secret}

      :ok =
        push!(octx, "C1", 1, "submitted", %{sha: sha("a"), data: %{"story_id" => other_story.id}})

      :ok = push!(octx, "C1", 2, "landed", %{sha: sha("a"), data: %{"merge_sha" => sha("c")}})
      :ok = push!(octx, "C1", 3, "reverted", %{sha: sha("a"), data: %{"landed_sha" => sha("c")}})

      forge(sha("c"), {:ok, true})
      assert {:ok, %Story{verified_status: :verified}} = verify(ctx, story)
    end
  end

  describe "the transaction probe the forge stub asserts with" do
    test "sees a transaction open in the process a task was started for", _ctx do
      AdminRepo.transaction(fn ->
        assert Task.async(fn -> any_caller_in_transaction?() end) |> Task.await()
      end)

      refute Task.async(fn -> any_caller_in_transaction?() end) |> Task.await()
    end
  end
end
