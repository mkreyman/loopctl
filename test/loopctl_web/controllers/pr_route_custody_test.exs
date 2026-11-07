defmodule LoopctlWeb.PrRouteCustodyTest do
  @moduledoc """
  AC-48.18.3 over HTTP: a story on the pull-request route is reported, reviewed and verified
  by control's verifier dispatch alone, so every other key meets `409 pr_route_verifier_only`
  — a separately rooted dispatch key on report, and the operator's own `:user` key (the
  human-operator permit) on review-complete. The story does not move.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ImplementerStart
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    ctx = fixture(:verify_ready_story, %{})
    {:ok, _} = ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)
    ctx
  end

  defp story(ctx), do: AdminRepo.get!(Story, ctx.story.id)

  test "a separately rooted dispatch key cannot report a pr-route story", ctx do
    other = fixture(:agent, %{tenant_id: ctx.tenant.id})

    {:ok, %{raw_key: raw_key}} =
      Dispatches.create_dispatch(ctx.tenant.id, %{
        role: :agent,
        agent_id: other.id,
        story_id: ctx.story.id
      })

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{})
      |> json_response(409)

    assert body["error"]["code"] == "pr_route_verifier_only"
    assert story(ctx).agent_status == :implementing
  end

  test "the operator's user key cannot record a review of a pr-route story", ctx do
    ctx.story
    |> Ecto.Changeset.change(agent_status: :reported_done, reported_done_at: DateTime.utc_now())
    |> AdminRepo.update!()

    {raw_key, _key} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :user})

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> post(~p"/api/v1/stories/#{ctx.story.id}/review-complete", %{"review_type" => "human"})
      |> json_response(409)

    assert body["error"]["code"] == "pr_route_verifier_only"
    assert AdminRepo.aggregate(Loopctl.Artifacts.ReviewRecord, :count) == 0
  end

  test "tenant isolation: another tenant's dispatch key cannot reach the story", ctx do
    other = fixture(:verify_ready_story, %{})

    {:ok, %{raw_key: raw_key}} =
      Dispatches.create_dispatch(other.tenant.id, %{
        role: :agent,
        agent_id: fixture(:agent, %{tenant_id: other.tenant.id}).id
      })

    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> post(~p"/api/v1/stories/#{ctx.story.id}/report", %{})
    |> json_response(404)

    assert story(ctx).agent_status == :implementing
  end
end
