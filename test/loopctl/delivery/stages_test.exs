defmodule Loopctl.Delivery.StagesTest do
  @moduledoc """
  Issue #803: the per-story delivery stage machine — compare-and-set transitions fenced by
  the claim epoch, idempotent side-effect identities, the audit-chain subset, and the
  runner-lost requeue the claim reclaimer performs.

  Everything `Stages` touches lives on the RLS `Loopctl.Repo` sandbox connection
  (`fixture(:stage_story)` makes the tenant there too), so this module is async. The
  reclaimer runs on `AdminRepo`, a separate sandbox connection, so its tests build their
  story and stage row on AdminRepo. Real concurrency — which one sandbox connection cannot
  produce — is in `Loopctl.Delivery.StagesLockTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReclaimExpiredClaimsWorker

  setup :verify_on_exit!

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  defp chain_actions(tenant_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id,
          order_by: [asc: e.chain_position],
          select: e.action
      )
    end)
  end

  # A story in `status` at `epoch` with its stage row at `stage`.
  defp at_stage(stage, attrs \\ %{}) do
    attrs = Map.new(attrs)

    story =
      fixture(:stage_story, %{
        claim_epoch: Map.get(attrs, :claim_epoch, 1),
        agent_status: Map.get(attrs, :agent_status, :assigned)
      })

    row_attrs =
      attrs
      |> Map.drop([:agent_status])
      |> Map.merge(%{tenant_id: story.tenant_id, story_id: story.id, stage: stage})
      |> Map.put_new(:claim_epoch, story.claim_epoch)
      |> then(fn a ->
        if stage == :escalated, do: Map.put_new(a, :escalation_reason, "why"), else: a
      end)

    {story, fixture(:story_stage, row_attrs)}
  end

  defp release_claim(story) do
    as_tenant(story.tenant_id, fn ->
      story = Repo.get!(Story, story.id)
      story |> Ecto.Changeset.change(Progress.claim_release_change(story)) |> Repo.update!()
    end)
  end

  describe "open/3" do
    test "creates the row at detected under the story's epoch, once" do
      story = fixture(:stage_story, %{claim_epoch: 3})

      assert {:ok, %StoryStage{stage: :detected, claim_epoch: 3} = row} =
               Stages.open(story.tenant_id, story.id)

      assert {:ok, again} = Stages.open(story.tenant_id, story.id)
      assert again.id == row.id

      assert [%StageEvent{event: "opened"}] = Stages.list_events(story.tenant_id, story.id)
    end

    test "refuses a story that is not in the tenant" do
      story = fixture(:stage_story, %{})
      other = fixture(:stage_story, %{})

      assert {:error, :not_found} = Stages.open(other.tenant_id, story.id)
    end
  end

  describe "the transition table" do
    test "every triple in StageMachine.transitions/0 advances, counts and chains as declared" do
      for {from, to, edge} <- StageMachine.transitions() do
        {story, row} = at_stage(from)

        opts =
          [
            claim_epoch: story.claim_epoch,
            reason: "because",
            actor_role: :user,
            actor_lineage: []
          ]

        result = Stages.advance(story.tenant_id, story.id, {from, to, edge}, opts)

        if edge in [:runner_lost, :claim_released] do
          # Only a releasing transaction takes these (follow_release/5).
          assert {:error, :invalid_transition} = result, inspect({from, to, edge})
        else
          assert {:ok, %StoryStage{stage: ^to} = moved} = result, inspect({from, to, edge})
          assert moved.lock_version == row.lock_version + 1

          expected_attempts =
            if StageMachine.counted?(edge), do: %{Atom.to_string(edge) => 1}, else: %{}

          assert moved.attempts == expected_attempts, inspect({from, to, edge})

          chained = chain_actions(story.tenant_id) != []
          assert chained == StageMachine.chained?(from, to), inspect({from, to, edge})
        end
      end
    end

    test "every triple NOT in the table is refused before the database is consulted" do
      edges = StageMachine.transitions() |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      stages = StageMachine.stages()
      missing = Ecto.UUID.generate()
      tenant = fixture(:stage_story, %{}).tenant_id

      refused =
        for from <- stages,
            to <- stages,
            edge <- edges,
            not StageMachine.allowed?(from, to, edge) do
          # A story that does not exist: :invalid_transition, not :not_found, proves the
          # refusal came first.
          assert {:error, :invalid_transition} =
                   Stages.advance(tenant, missing, {from, to, edge},
                     claim_epoch: 0,
                     reason: "r",
                     actor_role: :user
                   ),
                 inspect({from, to, edge})
        end

      assert refused != []
    end

    test "a repeated attempt counts again" do
      {story, _row} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch]

      {:ok, _} = Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red}, opts)

      [:implementing, :reviewing, :pr_open, :ci]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [from, to] ->
        {:ok, _} = Stages.advance(story.tenant_id, story.id, {from, to}, opts)
      end)

      {:ok, row} = Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red}, opts)
      assert row.attempts == %{"ci_red" => 2}
    end
  end

  describe "advance/4 refusals" do
    test "a replay of a committed transition is stale_stage and does not happen twice" do
      {story, _row} = at_stage(:implementing)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, first} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, opts)

      assert {:error, :stale_stage} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, opts)

      assert Stages.get(story.tenant_id, story.id).lock_version == first.lock_version
      assert length(Stages.list_events(story.tenant_id, story.id)) == 1
    end

    test "an epoch that is not the story's current one is stale_claim_epoch" do
      {story, _row} = at_stage(:implementing, claim_epoch: 2)

      assert {:error, :stale_claim_epoch} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing},
                 claim_epoch: 1
               )
    end

    test "a row behind the story's epoch is refused even to a caller presenting the current one" do
      {story, _row} = at_stage(:implementing, claim_epoch: 1)
      released = release_claim(story)

      assert {:error, :stale_claim_epoch} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing},
                 claim_epoch: released.claim_epoch
               )

      assert {:error, :stale_claim_epoch} =
               Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_a,
                 claim_epoch: released.claim_epoch
               )

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "entering claimed needs a claim, and rebinds the row to the claim's epoch" do
      {pending, _} = at_stage(:queued, agent_status: :pending, claim_epoch: 4)

      assert {:error, :not_claimed} =
               Stages.advance(pending.tenant_id, pending.id, {:queued, :claimed}, claim_epoch: 4)

      {story, _} = at_stage(:queued, claim_epoch: 5)

      as_tenant(story.tenant_id, fn ->
        Repo.update_all(from(s in StoryStage), set: [claim_epoch: 2])
      end)

      assert {:ok, %StoryStage{stage: :claimed, claim_epoch: 5}} =
               Stages.advance(story.tenant_id, story.id, {:queued, :claimed}, claim_epoch: 5)
    end

    test "human_resolution needs a human: a user role on a key no dispatch minted" do
      {story, _} = at_stage(:escalated)
      transition = {:escalated, :queued, :human_resolution}
      base = [claim_epoch: story.claim_epoch]

      assert {:error, :human_required} =
               Stages.advance(story.tenant_id, story.id, transition, base)

      assert {:error, :human_required} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [actor_role: :orchestrator, actor_lineage: []]
               )

      assert {:error, :human_required} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [actor_role: :user, actor_lineage: [Ecto.UUID.generate()]]
               )

      assert {:ok, %StoryStage{stage: :queued}} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [actor_role: :user, actor_lineage: []]
               )

      assert chain_actions(story.tenant_id) == ["story_stage_escalation_resolved"]
    end

    test "escalating needs a reason, and records it" do
      {story, _} = at_stage(:deployed)
      transition = {:deployed, :escalated, :verification_failed}

      assert {:error, :reason_required} =
               Stages.advance(story.tenant_id, story.id, transition,
                 claim_epoch: story.claim_epoch,
                 reason: "  "
               )

      assert {:ok, %StoryStage{escalation_reason: "smoke test failed"}} =
               Stages.advance(story.tenant_id, story.id, transition,
                 claim_epoch: story.claim_epoch,
                 reason: "smoke test failed"
               )

      assert chain_actions(story.tenant_id) == ["story_stage_escalated"]
    end

    test "no stage row is not_found" do
      story = fixture(:stage_story, %{})

      assert {:error, :not_found} =
               Stages.advance(story.tenant_id, story.id, {:detected, :triaged}, claim_epoch: 0)
    end
  end

  describe "record_effect/5" do
    @values %{
      worktree_path: "/home/runner/workspace/app/.claude/worktrees/us-1",
      branch: "feature/us-1",
      head_sha: String.duplicate("c", 40),
      pr_number: 821,
      merge_sha: String.duplicate("d", 64),
      release_id: "v421"
    }

    @others %{
      worktree_path: "/elsewhere",
      branch: "feature/other",
      head_sha: String.duplicate("e", 40),
      pr_number: 822,
      merge_sha: String.duplicate("f", 40),
      release_id: "v422"
    }

    test "a replay of every outward stage finds and reuses its recorded identity" do
      for effect <- StageMachine.effects() do
        [stage | _] = StageMachine.effect_stages(effect)
        {story, _} = at_stage(stage)
        value = effect_value(effect, story.tenant_id)
        opts = [claim_epoch: story.claim_epoch]

        assert {:ok, first} = Stages.record_effect(story.tenant_id, story.id, effect, value, opts)
        assert Map.fetch!(first, effect) == value

        assert {:ok, replay} =
                 Stages.record_effect(story.tenant_id, story.id, effect, value, opts)

        assert Map.fetch!(replay, effect) == value
        assert replay.lock_version == first.lock_version, inspect(effect)

        assert [%StageEvent{event: "effect_recorded"}] =
                 Stages.list_events(story.tenant_id, story.id)

        other = other_value(effect, story.tenant_id)

        assert {:error, :effect_conflict} =
                 Stages.record_effect(story.tenant_id, story.id, effect, other, opts),
               inspect(effect)

        assert Map.fetch!(Stages.get(story.tenant_id, story.id), effect) == value
      end
    end

    test "a stage that does not produce the effect cannot record it" do
      {story, _} = at_stage(:implementing)

      assert {:error, :wrong_stage} =
               Stages.record_effect(story.tenant_id, story.id, :pr_number, 5,
                 claim_epoch: story.claim_epoch
               )
    end

    test "a replay still succeeds after the stage moved on" do
      {story, _} = at_stage(:worktree)
      opts = [claim_epoch: story.claim_epoch]
      {:ok, _} = Stages.record_effect(story.tenant_id, story.id, :branch, "feature/x", opts)
      {:ok, _} = Stages.advance(story.tenant_id, story.id, {:worktree, :implementing}, opts)

      assert {:ok, %StoryStage{branch: "feature/x"}} =
               Stages.record_effect(story.tenant_id, story.id, :branch, "feature/x", opts)
    end

    test "a stale epoch cannot record" do
      {story, _} = at_stage(:implementing, claim_epoch: 2)

      assert {:error, :stale_claim_epoch} =
               Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_a, claim_epoch: 1)
    end

    test "malformed values are refused before the database" do
      story = fixture(:stage_story, %{})
      missing = Ecto.UUID.generate()

      for {effect, value} <- [
            {:head_sha, "ABC"},
            {:merge_sha, String.duplicate("a", 41)},
            {:pr_number, 0},
            {:pr_number, "7"},
            {:runner_id, "not-a-uuid"},
            {:branch, ""},
            {:branch, String.duplicate("b", 256)},
            {:worktree_path, "a" <> <<0>>},
            {:release_id, 5},
            {:stage, "done"}
          ] do
        assert {:error, :invalid_effect} =
                 Stages.record_effect(story.tenant_id, missing, effect, value, claim_epoch: 0),
               inspect({effect, value})
      end
    end

    test "going back to implementing clears the head, so the next head can be recorded" do
      {story, _} = at_stage(:ci, head_sha: @sha_a, branch: "feature/y", pr_number: 9)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, %StoryStage{head_sha: nil, branch: "feature/y", pr_number: 9}} =
               Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red}, opts)

      assert {:ok, %StoryStage{head_sha: @sha_b}} =
               Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_b, opts)
    end
  end

  describe "the audit chain" do
    test "a walk down the main line chains claimed and merged, and nothing else" do
      {story, _} = at_stage(:queued)
      opts = [claim_epoch: story.claim_epoch]

      [:queued, :claimed, :worktree, :implementing, :reviewing, :pr_open, :ci, :merged, :deployed]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [from, to] ->
        assert {:ok, _} = Stages.advance(story.tenant_id, story.id, {from, to}, opts)
      end)

      assert chain_actions(story.tenant_id) == ["story_stage_claimed", "story_stage_merged"]
      assert length(Stages.list_events(story.tenant_id, story.id)) == 8
    end

    test "a refused transition writes neither an event nor a chain entry" do
      {story, _} = at_stage(:ci)

      assert {:error, :stale_claim_epoch} =
               Stages.advance(story.tenant_id, story.id, {:ci, :merged}, claim_epoch: 99)

      assert chain_actions(story.tenant_id) == []
      assert Stages.list_events(story.tenant_id, story.id) == []
    end
  end

  describe "tenant isolation" do
    test "tenant B sees none of tenant A's stage rows or events, and cannot write them" do
      {story_a, _} = at_stage(:implementing)

      {:ok, _} =
        Stages.advance(story_a.tenant_id, story_a.id, {:implementing, :reviewing}, claim_epoch: 1)

      story_b = fixture(:stage_story, %{})

      # No explicit predicate: RLS alone must hide A's rows from B.
      assert as_tenant(story_b.tenant_id, fn -> Repo.all(StoryStage) end) == []
      assert as_tenant(story_b.tenant_id, fn -> Repo.all(StageEvent) end) == []
      assert as_tenant(story_a.tenant_id, fn -> Repo.all(StoryStage) end) != []

      assert Stages.get(story_b.tenant_id, story_a.id) == nil
      assert Stages.list_events(story_b.tenant_id, story_a.id) == []

      assert {:error, :not_found} =
               Stages.advance(story_b.tenant_id, story_a.id, {:reviewing, :pr_open},
                 claim_epoch: 1
               )

      assert {:error, :not_found} =
               Stages.record_effect(story_b.tenant_id, story_a.id, :head_sha, @sha_a,
                 claim_epoch: 1
               )

      assert Stages.get(story_a.tenant_id, story_a.id).stage == :reviewing
    end
  end

  describe "claim releases (follow_release/5)" do
    # On AdminRepo: every release path's connection.
    defp claimed_with_stage(stage, row_attrs \\ %{}, story_attrs \\ %{}) do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      story =
        fixture(
          :story,
          Map.merge(%{tenant_id: tenant.id, agent_status: :contracted}, story_attrs)
        )

      {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

      row =
        fixture(
          :story_stage,
          %{
            repo: AdminRepo,
            tenant_id: tenant.id,
            story_id: story.id,
            stage: stage,
            claim_epoch: claimed.claim_epoch
          }
          |> Map.merge(escalation(stage))
          |> Map.merge(row_attrs)
        )

      %{tenant_id: tenant.id, agent: agent, story: claimed, row: row}
    end

    defp expire_lease(story) do
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60)])
    end

    defp report_done(story) do
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(
          set: [agent_status: :reported_done, reported_done_at: DateTime.utc_now()]
        )
    end

    defp orchestrator(tenant_id),
      do: fixture(:agent, %{tenant_id: tenant_id, agent_type: :orchestrator})

    # Every path that releases a claim, as its production caller runs it. Each returns the
    # edge it is recorded under.
    defp release(:reclaim, %{story: story}) do
      expire_lease(story)
      assert :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})
      :runner_lost
    end

    defp release(:unclaim, %{tenant_id: t, story: story, agent: agent}) do
      {:ok, _} = Progress.unclaim_story(t, story.id, agent_id: agent.id)
      :claim_released
    end

    defp release(:force_unclaim, %{tenant_id: t, story: story}) do
      {:ok, _} = Progress.force_unclaim_story(t, story.id)
      :claim_released
    end

    defp release(:reject, %{tenant_id: t, story: story}) do
      report_done(story)

      {:ok, %Story{agent_status: :pending}} =
        Progress.reject_story(t, story.id, %{"reason" => "Missing tests"},
          orchestrator_agent_id: orchestrator(t).id
        )

      :claim_released
    end

    defp release(:bulk_reject, %{tenant_id: t, story: story}) do
      report_done(story)

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_reject(
          t,
          [%{"story_id" => story.id, "reason" => "Missing tests"}],
          orchestrator(t).id,
          verifier_lineage: []
        )

      :claim_released
    end

    @release_paths [:reclaim, :unclaim, :force_unclaim, :reject, :bulk_reject]

    for path <- @release_paths do
      test "#{path}: the in-flight stage row goes back to queued in the same transaction" do
        ctx =
          claimed_with_stage(:implementing, %{
            worktree_path: "/w",
            head_sha: @sha_a,
            branch: "feature/z",
            pr_number: 12,
            attempts: %{"ci_red" => 1}
          })

        edge = release(unquote(path), ctx)

        story = AdminRepo.get!(Story, ctx.story.id)
        assert story.claim_epoch > ctx.story.claim_epoch

        requeued = AdminRepo.get!(StoryStage, ctx.row.id)
        assert requeued.stage == :queued
        assert requeued.claim_epoch == story.claim_epoch
        assert requeued.attempts == %{"ci_red" => 1, Atom.to_string(edge) => 1}
        assert requeued.lock_version == ctx.row.lock_version + 1
        assert {requeued.worktree_path, requeued.head_sha} == {nil, nil}
        assert {requeued.branch, requeued.pr_number} == {"feature/z", 12}

        edge_name = Atom.to_string(edge)

        assert [%StageEvent{from_stage: "implementing", to_stage: "queued", edge: ^edge_name}] =
                 AdminRepo.all(from e in StageEvent, where: e.story_stage_id == ^ctx.row.id)
      end
    end

    test "every stage: in flight is requeued, done and failed untouched, the rest rebound" do
      for stage <- StageMachine.stages() do
        ctx = claimed_with_stage(stage)
        expire_lease(ctx.story)

        {:ok, released} =
          Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)

        after_release = AdminRepo.get!(StoryStage, ctx.row.id)

        cond do
          stage in StageMachine.in_flight_stages() ->
            assert {after_release.stage, after_release.claim_epoch} ==
                     {:queued, released.claim_epoch},
                   inspect(stage)

          stage in [:done, :failed] ->
            assert after_release == ctx.row, inspect(stage)

          true ->
            assert {after_release.stage, after_release.claim_epoch, after_release.attempts} ==
                     {stage, released.claim_epoch, %{}},
                   inspect(stage)

            assert [%StageEvent{event: "rebound"}] =
                     AdminRepo.all(from e in StageEvent, where: e.story_stage_id == ^ctx.row.id)
        end
      end
    end

    test "force-unclaim of an already-pending story rebinds a row a release left behind" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id})

      {1, _} =
        from(s in Story, where: s.id == ^story.id) |> AdminRepo.update_all(set: [claim_epoch: 3])

      row =
        fixture(:story_stage, %{
          repo: AdminRepo,
          tenant_id: tenant.id,
          story_id: story.id,
          stage: :merged,
          claim_epoch: 2
        })

      {:ok, %Story{claim_epoch: 3}} = Progress.force_unclaim_story(tenant.id, story.id)
      assert %StoryStage{stage: :merged, claim_epoch: 3} = AdminRepo.get!(StoryStage, row.id)

      # Again: already at the story's epoch, nothing to write.
      {:ok, _} = Progress.force_unclaim_story(tenant.id, story.id)
      assert AdminRepo.get!(StoryStage, row.id).lock_version == row.lock_version + 1
    end

    test "a reclaim that refuses (lease renewed) leaves the stage row in flight" do
      ctx = claimed_with_stage(:ci)

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)

      assert AdminRepo.get!(StoryStage, ctx.row.id).stage == :ci
    end

    test "follow_release/5 refuses to run outside a releasing transaction" do
      assert_raise ArgumentError, fn ->
        Stages.follow_release(Ecto.UUID.generate(), Ecto.UUID.generate(), 1, :claim_released)
      end
    end
  end

  describe "claims (follow_claim/4)" do
    # A claim bumps the epoch as a release does, so the row has to follow it or a story
    # claimed before triage finished can never be advanced again.
    defp contracted_story_with_stage(stage) do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})

      row =
        fixture(:story_stage, %{
          repo: AdminRepo,
          tenant_id: tenant.id,
          story_id: story.id,
          stage: stage,
          claim_epoch: story.claim_epoch
        })

      %{tenant_id: tenant.id, agent: agent, story: story, row: row}
    end

    for stage <- [:detected, :triaged, :queued] do
      test "a hand-claimed story at #{stage} keeps its stage and takes the claim's epoch" do
        %{tenant_id: t, agent: agent, story: story, row: row} =
          contracted_story_with_stage(unquote(stage))

        {:ok, claimed} = Progress.claim_story(t, story.id, agent_id: agent.id)
        assert claimed.claim_epoch == story.claim_epoch + 1

        rebound = AdminRepo.get!(StoryStage, row.id)
        assert rebound.stage == unquote(stage)
        assert rebound.claim_epoch == claimed.claim_epoch
        assert rebound.attempts == %{}

        assert [%StageEvent{event: "rebound"}] =
                 AdminRepo.all(from e in StageEvent, where: e.story_stage_id == ^row.id)
      end
    end

    test "a bulk claim rebinds the row the same way" do
      %{tenant_id: t, agent: agent, story: story, row: row} = contracted_story_with_stage(:queued)

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_claim(t, [story.id], agent.id)

      claimed = AdminRepo.get!(Story, story.id)
      assert AdminRepo.get!(StoryStage, row.id).claim_epoch == claimed.claim_epoch
    end

    test "follow_claim/4 refuses to run outside the claiming transaction" do
      assert_raise ArgumentError, fn ->
        Stages.follow_claim(Ecto.UUID.generate(), Ecto.UUID.generate(), 1)
      end
    end
  end

  defp escalation(:escalated), do: %{escalation_reason: "why"}
  defp escalation(_stage), do: %{}

  defp effect_value(:runner_id, tenant_id), do: fixture(:stage_runner, %{tenant_id: tenant_id}).id
  defp effect_value(effect, _tenant_id), do: Map.fetch!(@values, effect)

  defp other_value(:runner_id, tenant_id), do: fixture(:stage_runner, %{tenant_id: tenant_id}).id
  defp other_value(effect, _tenant_id), do: Map.fetch!(@others, effect)
end
