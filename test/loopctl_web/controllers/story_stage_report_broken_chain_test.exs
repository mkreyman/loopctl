defmodule LoopctlWeb.StoryStageReportBrokenChainTest do
  @moduledoc """
  US-45.9: a claimant's stage report against a tenant whose audit chain refuses the append
  answers `audit_chain_append_failed`, not a 500 crash, and the row does not move. The rest of
  the endpoint is in `LoopctlWeb.StoryStageReportControllerTest`, async.

  ## Why `async: false` and COMMITTED

  The SUBJECT is a broken chain, and the chain's own trigger cannot be driven to that state
  through the application, so the test installs a refusing trigger on the shared
  `audit_chain` table (as `Loopctl.Delivery.SessionEndReleaseTest` does). That is DDL on a
  table every test appends to: inside an async test's sandbox the trigger's lock would be held
  until the test ended, stalling every other test's chain append (`Loopctl.Test.LockGuard`
  fails such a test at teardown). So the trigger is COMMITTED, scoped to this test's tenant
  and dropped on exit, which only a module ExUnit runs alone may do.

  The rows are committed too, for an ordering reason: the setup's contract and claim append to
  the chain, so a sandboxed setup would hold a row lock on `audit_chain` that the committed
  `CREATE TRIGGER` waits on for the rest of the test. The tenants the module made are swept
  when it ends (`track_committed_tenants/0`).
  """

  use LoopctlWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Test.BrokenChain

  setup :verify_on_exit!

  setup_all do
    %{committed: track_committed_tenants()}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A contracted story standing at `queued`, its project bound to a thread-mode source, and a
  # claim on it by the agent whose key reports.
  # This module's tenants only: the marker sweep would also delete another worktree's
  # committed rows.
  defp claimed_story(ctx) do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    track_committed_tenant(ctx.committed, tenant.id)
    {raw_key, _api_key, agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    story = fixture(:committed_story, %{tenant_id: tenant.id})

    story =
      unboxed(fn ->
        {:ok, story} =
          Progress.contract_story(tenant.id, story.id, %{},
            actor_label: "test",
            skip_contract_check: true
          )

        {:ok, _} = Stages.open(tenant.id, story.id, actor_label: "test")

        for {from, to} <- [{:detected, :triaged}, {:triaged, :queued}] do
          {:ok, _} =
            Stages.advance(tenant.id, story.id, {from, to}, claim_epoch: story.claim_epoch)
        end

        bind_thread_source(tenant.id, story)

        {:ok, story} =
          Progress.claim_story(tenant.id, story.id,
            agent_id: agent.id,
            actor_label: "agent:test",
            lineage: []
          )

        story
      end)

    %{tenant: tenant, story: story, raw: raw_key}
  end

  defp bind_thread_source(tenant_id, story) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Source{
      tenant_id: tenant_id,
      project_id: story.project_id,
      repo_full_name: "mkreyman/infra",
      base_branch: "master",
      mode: :thread,
      required_checks: ["test"],
      webhook_secret: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    })
  end

  @tag :capture_log
  test "a broken audit chain answers audit_chain_append_failed, not a 500",
       %{conn: conn} = ctx do
    %{tenant: tenant, story: story, raw: raw} = claimed_story(ctx)
    BrokenChain.install!(tenant.id)

    body = %{"claim_epoch" => story.claim_epoch, "from" => "claimed", "to" => "worktree"}

    assert %{"error" => %{"code" => "audit_chain_append_failed"}} =
             conn
             |> auth(raw)
             |> post(~p"/api/v1/stories/#{story.id}/stage/transitions", body)
             |> json_response(500)

    assert %StoryStage{stage: :queued} = unboxed(fn -> Stages.get(tenant.id, story.id) end)
  end
end
