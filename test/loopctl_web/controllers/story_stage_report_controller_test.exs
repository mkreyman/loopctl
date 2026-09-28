defmodule LoopctlWeb.StoryStageReportControllerTest do
  @moduledoc """
  US-45.9: an interactive claim records its route, and its claimant reports its own stages.

  `async: false` and COMMITTED, for the reason `Loopctl.Delivery.PlacementTest` gives: a claim
  is an `AdminRepo` transaction and `queued -> claimed` a chained `Loopctl.Repo` one, and two
  sandbox connections cannot see each other's work. `sweep_committed_runner_tenants/0` removes
  everything at the boundary.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.BulkOperations
  alias Loopctl.Delivery.ClaimRoute
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ThreadMergeSweepWorker

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @sha String.duplicate("a", 40)

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Repo, fun) end)

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

  defp step(story, from, to, extra \\ %{}),
    do: Map.merge(%{"claim_epoch" => story.claim_epoch, "from" => from, "to" => to}, extra)

  describe "the interactive claim's route" do
    test "a thread claim of a queued story binds thread, the base and a loop/ branch, and enters claimed" do
      ctx = setup_story()
      story = claim(ctx)

      assert %ClaimRoute{mode: "thread", base_branch: "master", branch: "loop/" <> _} =
               route(ctx, story)

      assert %StoryStage{stage: :claimed, claim_epoch: epoch} = row(ctx)
      assert epoch == story.claim_epoch
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

    test "the claim's own queued -> claimed is made first when it did not land", %{conn: conn} do
      ctx = setup_story()

      unboxed(fn ->
        {:ok, _} = BulkOperations.bulk_claim(ctx.tenant.id, [ctx.story.id], ctx.agent.id)
      end)

      {:ok, story} = unboxed(fn -> Stories.get_story(ctx.tenant.id, ctx.story.id) end)

      assert %{"stage" => %{"stage" => "worktree"}} =
               conn
               |> report(ctx.raw, story, step(story, "claimed", "worktree"))
               |> json_response(200)
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

      assert %StoryStage{stage: :claimed} = sandboxed_row(ctx)
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

      assert %StoryStage{stage: :claimed} = sandboxed_row(ctx)
    end
  end
end
