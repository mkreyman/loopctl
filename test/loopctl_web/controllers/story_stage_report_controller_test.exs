defmodule LoopctlWeb.StoryStageReportControllerTest do
  @moduledoc """
  US-45.9: an interactive claim records its route, and its claimant reports its own stages.

  `async: false` and COMMITTED, for the reason `Loopctl.Delivery.PlacementTest` gives: a claim
  is an `AdminRepo` transaction and `queued -> claimed` a chained `Loopctl.Repo` one, and two
  sandbox connections cannot see each other's work. It cannot be async, which the suite's
  default asks for: `sweep_committed_runner_tenants/0` deletes EVERY committed runner tenant
  at the boundary, a concurrent file's included, and the broken-chain test installs committed
  DDL on the shared `audit_chain` table.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.BulkOperations
  alias Loopctl.Delivery.ClaimRoute
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.InteractiveClaims
  alias Loopctl.Delivery.RetryCeiling
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Presence
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ThreadMergeSweepWorker

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @sha String.duplicate("a", 40)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A contracted story standing at `stage` (`:queued` by default), its project bound to a
  # source in `mode`, and an agent key to claim it with.
  defp setup_story(opts \\ []) do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw_key, api_key, agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    {other_raw, _other_key, _other} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    story = fixture(:committed_story, %{tenant_id: tenant.id})

    story =
      unboxed(fn ->
        {:ok, story} =
          Progress.contract_story(tenant.id, story.id, %{},
            actor_label: "test",
            skip_contract_check: true
          )

        {:ok, _} = Stages.open(tenant.id, story.id, actor_label: "test")
        epoch = story.claim_epoch

        for {from, to} <- stage_path(Keyword.get(opts, :stage, :queued)) do
          {:ok, _} = Stages.advance(tenant.id, story.id, {from, to}, claim_epoch: epoch)
        end

        if mode = Keyword.get(opts, :mode, :thread), do: bind(tenant.id, story, mode)
        story
      end)

    %{
      tenant: tenant,
      story: story,
      agent: agent,
      api_key: api_key,
      raw: raw_key,
      other: other_raw
    }
  end

  defp stage_path(:detected), do: []
  defp stage_path(:queued), do: [{:detected, :triaged}, {:triaged, :queued}]

  defp bind(tenant_id, story, mode) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Source{
      tenant_id: tenant_id,
      project_id: story.project_id,
      repo_full_name: "mkreyman/infra",
      base_branch: "master",
      mode: mode,
      required_checks: if(mode == :thread, do: ["test"], else: []),
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })
  end

  defp claim(ctx, opts \\ []) do
    unboxed(fn ->
      {:ok, story} =
        Progress.claim_story(
          ctx.tenant.id,
          ctx.story.id,
          [agent_id: ctx.agent.id, actor_label: "agent:test", lineage: []] ++ opts
        )

      story
    end)
  end

  defp route(_ctx, story) do
    unboxed(fn ->
      AdminRepo.one(
        from r in ClaimRoute,
          where: r.story_id == ^story.id and r.claim_epoch == ^story.claim_epoch
      )
    end)
  end

  defp row(ctx), do: unboxed(fn -> Stages.get(ctx.tenant.id, ctx.story.id) end)

  # After an HTTP call: the controller writes on this test's sandbox connection, which an
  # unboxed read cannot see.
  defp sandboxed_row(ctx), do: Stages.get(ctx.tenant.id, ctx.story.id)

  defp report(conn, key, story, body) do
    conn |> auth(key) |> post(~p"/api/v1/stories/#{story.id}/stage/transitions", body)
  end

  # A tenant chain that refuses appends as a HASH VIOLATION, installed for this tenant only
  # and committed, as `Loopctl.Delivery.SessionEndReleaseTest` does it: the chain's own trigger
  # cannot be driven to that state through the application.
  defp break_chain(tenant_id) do
    name = "test_broken_chain_" <> String.replace(tenant_id, "-", "")

    unboxed(fn ->
      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'audit_chain_hash_violation: injected by test' USING ERRCODE = 'P0001';
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE INSERT ON audit_chain FOR EACH ROW
      WHEN (NEW.tenant_id = '#{tenant_id}') EXECUTE FUNCTION #{name}()
      """)
    end)

    on_exit(fn ->
      unboxed(fn ->
        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON audit_chain")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)
    end)
  end

  defp step(story, from, to, extra \\ %{}),
    do: Map.merge(%{"claim_epoch" => story.claim_epoch, "from" => from, "to" => to}, extra)

  describe "the interactive claim's route" do
    test "a thread claim of a queued story binds thread, the base and a loop/ branch; the row waits" do
      ctx = setup_story()
      story = claim(ctx)

      assert %ClaimRoute{mode: "thread", base_branch: "master", branch: "loop/" <> _} =
               route(ctx, story)

      # The claim does not move the row: the claimant's first report does.
      assert %StoryStage{stage: :queued} = row(ctx)
    end

    test "every reader sees the route bound at the claim, never the source's current setting" do
      ctx = setup_story()
      story = claim(ctx)

      unboxed(fn ->
        from(s in Source, where: s.project_id == ^story.project_id)
        |> AdminRepo.update_all(set: [mode: :pr, base_branch: "release"])
      end)

      assert {:ok, %{mode: :thread, base_branch: "master"}} =
               unboxed(fn -> DispatchPayload.dispatch_route(ctx.tenant.id, story) end)

      # The sweep's candidate read, over the same derivation.
      unboxed(fn ->
        from(s in StoryStage, where: s.story_id == ^story.id)
        |> AdminRepo.update_all(set: [stage: :ci, merge_gate_allowed_sha: @sha])
      end)

      candidates = unboxed(fn -> AdminRepo.all(ThreadMergeSweepWorker.candidates_query()) end)
      assert {ctx.tenant.id, story.id} in candidates
    end

    test "a story not at queued gets a pr route: it cannot merge in thread mode however claimed" do
      ctx = setup_story(stage: :detected)
      story = claim(ctx)

      assert %ClaimRoute{mode: "pr", base_branch: "master", branch: nil} = route(ctx, story)
    end

    test "a project with no intake source records no route" do
      ctx = setup_story(mode: nil)
      story = claim(ctx)

      assert route(ctx, story) == nil
    end

    test "a placement's claim records no interactive route; its ledger row is its route" do
      ctx = setup_story()
      story = claim(ctx, placement: true)

      assert route(ctx, story) == nil
      assert %StoryStage{stage: :queued} = row(ctx)
    end

    test "a bulk claim records the route too, and leaves the stage move to the claimant" do
      ctx = setup_story()

      unboxed(fn ->
        {:ok, _} = BulkOperations.bulk_claim(ctx.tenant.id, [ctx.story.id], ctx.agent.id)
      end)

      story = unboxed(fn -> Stories.get_story(ctx.tenant.id, ctx.story.id) end) |> elem(1)
      assert %ClaimRoute{mode: "thread"} = route(ctx, story)
      assert %StoryStage{stage: :queued} = row(ctx)
    end
  end

  describe "POST /stories/:id/stage/transitions" do
    test "the claimant reports forward as a runner would, up to ci with its head", %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)

      for {from, to} <- [
            {"claimed", "worktree"},
            {"worktree", "implementing"},
            {"implementing", "reviewing"},
            {"reviewing", "pr_open"}
          ] do
        assert %{"stage" => %{"stage" => ^to}} =
                 build_conn()
                 |> report(ctx.raw, story, step(story, from, to))
                 |> json_response(200)
      end

      body = step(story, "pr_open", "ci", %{"effects" => %{"head_sha" => @sha}})

      assert %{"stage" => %{"stage" => "ci"}} =
               conn |> report(ctx.raw, story, body) |> json_response(200)

      assert %StoryStage{stage: :ci, head_sha: @sha} = sandboxed_row(ctx)
      assert {:ok, %DateTime{}} = Stages.entered_at(ctx.tenant.id, story.id, :ci)
    end

    test "the first report enters the claim, for a bulk claim too", %{conn: conn} do
      ctx = setup_story()

      unboxed(fn ->
        {:ok, _} = BulkOperations.bulk_claim(ctx.tenant.id, [ctx.story.id], ctx.agent.id)
      end)

      {:ok, story} = unboxed(fn -> Stories.get_story(ctx.tenant.id, ctx.story.id) end)

      assert %{"stage" => %{"stage" => "worktree"}} =
               conn
               |> report(ctx.raw, story, step(story, "claimed", "worktree"))
               |> json_response(200)

      assert {:ok, %DateTime{}} = Stages.entered_at(ctx.tenant.id, story.id, :claimed)
    end

    test "a claim released before any report spends no attempt; after one, it spends one" do
      ctx = setup_story()
      story = claim(ctx)

      unboxed(fn ->
        {:ok, _} = Progress.unclaim_story(ctx.tenant.id, story.id, agent_id: ctx.agent.id)
      end)

      assert %StoryStage{stage: :queued, attempts: attempts} = row(ctx)
      assert RetryCeiling.counted_releases(attempts) == 0

      {:ok, recontracted} = unboxed(fn -> Stories.get_story(ctx.tenant.id, story.id) end)
      again = claim(%{ctx | story: recontracted})

      # The move the first report makes, committed here: an HTTP report writes on this test's
      # sandbox connection, whose uncommitted locks an unboxed unclaim would wait on.
      unboxed(fn ->
        {:ok, _} =
          InteractiveClaims.enter_claimed(ctx.tenant.id, again,
            actor_label: "agent:test",
            actor_role: :agent,
            actor_lineage: []
          )

        {:ok, _} = Progress.unclaim_story(ctx.tenant.id, again.id, agent_id: ctx.agent.id)
      end)

      assert RetryCeiling.counted_releases(row(ctx).attempts) == 1
    end

    test "refused for another agent, another epoch, and a transition no runner may report", %{
      conn: conn
    } do
      ctx = setup_story()
      story = claim(ctx)

      assert %{"error" => %{"code" => "not_claimant"}} =
               conn
               |> report(ctx.other, story, step(story, "claimed", "worktree"))
               |> json_response(409)

      stale = %{step(story, "claimed", "worktree") | "claim_epoch" => story.claim_epoch + 1}

      assert %{"error" => %{"code" => "stale_claim_epoch"}} =
               build_conn() |> report(ctx.raw, story, stale) |> json_response(409)

      assert %{"error" => %{"code" => "invalid_payload"}} =
               build_conn()
               |> report(ctx.raw, story, step(story, "claimed", "merged"))
               |> json_response(422)

      assert %StoryStage{stage: :queued} = sandboxed_row(ctx)
    end

    test "refused on a pr claim and on a placed claim: they have no interactive thread route", %{
      conn: conn
    } do
      pr = setup_story(stage: :detected)
      pr_story = claim(pr)

      assert %{"error" => %{"code" => "not_interactive_thread_claim"}} =
               conn
               |> report(pr.raw, pr_story, step(pr_story, "claimed", "worktree"))
               |> json_response(409)

      placed = setup_story()
      placed_story = claim(placed, placement: true)

      assert %{"error" => %{"code" => "not_interactive_thread_claim"}} =
               build_conn()
               |> report(placed.raw, placed_story, step(placed_story, "claimed", "worktree"))
               |> json_response(409)
    end

    test "refused once the claim's lease has run out", %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)

      unboxed(fn ->
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60)])
      end)

      assert %{"error" => %{"code" => "claim_not_live"}} =
               conn
               |> report(ctx.raw, story, step(story, "claimed", "worktree"))
               |> json_response(409)

      assert %StoryStage{stage: :queued} = sandboxed_row(ctx)
    end

    test "the claimant may not report the merge: loopctl records it", %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)

      unboxed(fn ->
        from(r in StoryStage, where: r.story_id == ^story.id)
        |> AdminRepo.update_all(set: [stage: :ci, head_sha: @sha])
      end)

      body = step(story, "ci", "merged", %{"effects" => %{"merge_sha" => @sha}})

      assert %{"error" => %{"code" => "invalid_payload"}} =
               conn |> report(ctx.raw, story, body) |> json_response(422)

      assert %StoryStage{stage: :ci} = sandboxed_row(ctx)
    end

    test "after loopctl merges, the claimant reports the deploy, never undoes the merge", %{
      conn: conn
    } do
      ctx = setup_story()
      story = claim(ctx)

      unboxed(fn ->
        from(r in StoryStage, where: r.story_id == ^story.id)
        |> AdminRepo.update_all(
          set: [stage: :merged, claim_epoch: story.claim_epoch, head_sha: @sha, merge_sha: @sha]
        )
      end)

      refused =
        step(story, "merged", "implementing", %{"edge" => "merge_refused", "reason" => "x"})

      assert %{"error" => %{"code" => "invalid_payload"}} =
               conn |> report(ctx.raw, story, refused) |> json_response(422)

      deployed = step(story, "merged", "deployed", %{"effects" => %{"release_id" => "v42"}})

      assert %{"stage" => %{"stage" => "deployed"}} =
               build_conn() |> report(ctx.raw, story, deployed) |> json_response(200)

      assert %StoryStage{stage: :deployed, release_id: "v42"} = sandboxed_row(ctx)
    end

    test "a head that differs from the one recorded earlier is effect_conflict, naming it", %{
      conn: conn
    } do
      ctx = setup_story()
      story = claim(ctx)

      for {from, to} <- [{"claimed", "worktree"}, {"worktree", "implementing"}] do
        build_conn() |> report(ctx.raw, story, step(story, from, to)) |> json_response(200)
      end

      first = step(story, "implementing", "reviewing", %{"effects" => %{"head_sha" => @sha}})
      build_conn() |> report(ctx.raw, story, first) |> json_response(200)

      build_conn()
      |> report(ctx.raw, story, step(story, "reviewing", "pr_open"))
      |> json_response(200)

      other = String.duplicate("b", 40)
      body = step(story, "pr_open", "ci", %{"effects" => %{"head_sha" => other}})

      assert %{
               "error" => %{
                 "code" => "effect_conflict",
                 "stage" => "pr_open",
                 "recorded_effects" => %{"head_sha" => @sha}
               }
             } = conn |> report(ctx.raw, story, body) |> json_response(409)
    end

    test "a claim that requested review is no longer live, as for its checkpoints", %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)

      unboxed(fn ->
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(set: [review_requested_at: DateTime.utc_now()])
      end)

      assert %{"error" => %{"code" => "claim_not_live"}} =
               conn
               |> report(ctx.raw, story, step(story, "claimed", "worktree"))
               |> json_response(409)
    end

    test "another tenant's agent cannot see the story at all", %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)
      stranger = setup_story()

      assert conn
             |> report(stranger.raw, story, step(story, "claimed", "worktree"))
             |> json_response(404)
    end
  end

  describe "the route under the claim" do
    test "a leftover row at the claim's epoch is overwritten, never refused" do
      ctx = setup_story()
      next_epoch = ctx.story.claim_epoch + 1

      unboxed(fn ->
        AdminRepo.insert!(%ClaimRoute{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          claim_epoch: next_epoch,
          mode: "pr",
          base_branch: "stale"
        })
      end)

      story = claim(ctx)
      assert story.claim_epoch == next_epoch
      assert %ClaimRoute{mode: "thread", base_branch: "master"} = route(ctx, story)
    end

    test "the thread branch is the PRD's loop/<story>, whatever a connected runner declares" do
      ctx = setup_story()
      topic = Runners.pool_topic(ctx.tenant.id)
      {:ok, _} = Presence.track(self(), topic, Ecto.UUID.generate(), %{branch_prefixes: ["bot/"]})

      story = claim(ctx)
      assert %ClaimRoute{branch: "loop/" <> _} = route(ctx, story)
    end

    test "the claim response names the route to push to", %{conn: conn} do
      ctx = setup_story()

      assert %{"route" => %{"mode" => "thread", "branch" => "loop/" <> _}} =
               conn
               |> auth(ctx.raw)
               |> post(~p"/api/v1/stories/#{ctx.story.id}/claim", %{})
               |> json_response(200)
    end

    test "the claimed move demands a resolved lineage rather than defaulting one" do
      ctx = setup_story()

      assert_raise KeyError, fn ->
        InteractiveClaims.enter_claimed(ctx.tenant.id, ctx.story,
          actor_label: "test",
          actor_role: :agent
        )
      end
    end

    test "a resend of a report that landed answers the row, replayed; a different one names the record",
         %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)

      for {from, to} <- [
            {"claimed", "worktree"},
            {"worktree", "implementing"},
            {"implementing", "reviewing"},
            {"reviewing", "pr_open"}
          ] do
        build_conn() |> report(ctx.raw, story, step(story, from, to)) |> json_response(200)
      end

      body = step(story, "pr_open", "ci", %{"effects" => %{"head_sha" => @sha}})

      assert %{"replayed" => false} =
               conn |> report(ctx.raw, story, body) |> json_response(200)

      assert %{"replayed" => true, "stage" => %{"stage" => "ci"}} =
               build_conn() |> report(ctx.raw, story, body) |> json_response(200)

      other =
        step(story, "pr_open", "ci", %{"effects" => %{"head_sha" => String.duplicate("b", 40)}})

      assert %{
               "error" => %{
                 "code" => "effect_conflict",
                 "stage" => "ci",
                 "recorded_effects" => %{"head_sha" => @sha}
               }
             } =
               build_conn() |> report(ctx.raw, story, other) |> json_response(409)

      behind = step(story, "reviewing", "pr_open")

      assert %{"error" => %{"code" => "stale_stage", "stage" => "ci"}} =
               build_conn() |> report(ctx.raw, story, behind) |> json_response(409)
    end

    @tag :capture_log
    test "a broken audit chain answers audit_chain_append_failed, not a 500", %{conn: conn} do
      ctx = setup_story()
      story = claim(ctx)
      break_chain(ctx.tenant.id)

      assert %{"error" => %{"code" => "audit_chain_append_failed"}} =
               conn
               |> report(ctx.raw, story, step(story, "claimed", "worktree"))
               |> json_response(500)

      assert %StoryStage{stage: :queued} = row(ctx)
    end
  end
end
