defmodule LoopctlWeb.PrRouteRejectTest do
  @moduledoc """
  TC-48.18.4: a key no dispatch minted may still REJECT dispatch-minted work — sending work
  back is remediation — EXCEPT on a story whose delivery stage is on a pr-mode source. Control
  verifies such a story under its own verifier dispatch (US-48.18), and an unlineaged
  orchestrator key rejecting it would let any session send another machine's work back. The
  refusal is `409 caller_lineage_required`, and the story does not move.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    ctx = fixture(:verify_ready_story, %{})

    ctx.story
    |> Ecto.Changeset.change(agent_status: :reported_done, reported_done_at: DateTime.utc_now())
    |> AdminRepo.update!()

    orch = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

    {raw_key, _key} =
      fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator, agent_id: orch.id})

    Map.put(ctx, :orch_key, raw_key)
  end

  defp reject(ctx) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{ctx.orch_key}")
    |> post(~p"/api/v1/stories/#{ctx.story.id}/reject", %{"reason" => "send it back"})
  end

  defp story(ctx), do: AdminRepo.get!(Story, ctx.story.id)

  test "an unlineaged orchestrator key cannot reject a pr-route story", ctx do
    body = ctx |> reject() |> json_response(409)

    assert body["error"]["code"] == "caller_lineage_required"

    story = story(ctx)
    assert story.verified_status == :unverified
    assert story.agent_status == :reported_done
  end

  test "the same key still rejects the same story once it is on no live pr-mode source", ctx do
    {1, _} =
      from(s in Loopctl.Intake.Source, where: s.id == ^ctx.source.id)
      |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

    body = ctx |> reject() |> json_response(200)
    assert body["story"]["verified_status"] == "rejected"
  end

  test "bulk reject refuses the pr-route story per story, with the same code", ctx do
    results =
      build_conn()
      |> put_req_header("authorization", "Bearer #{ctx.orch_key}")
      |> post(~p"/api/v1/stories/bulk/reject", %{
        "stories" => [%{"story_id" => ctx.story.id, "reason" => "send it back"}]
      })
      |> json_response(422)
      |> Map.fetch!("results")

    assert [%{"status" => "error"} = result] = results
    assert inspect(result) =~ "caller_lineage_required"
    assert story(ctx).verified_status == :unverified
  end

  test "tenant isolation: another tenant's key cannot reach the story at all", ctx do
    other = fixture(:verify_ready_story, %{})
    orch = fixture(:agent, %{tenant_id: other.tenant.id, agent_type: :orchestrator})

    {raw_key, _} =
      fixture(:api_key, %{tenant_id: other.tenant.id, role: :orchestrator, agent_id: orch.id})

    assert ctx
           |> Map.put(:orch_key, raw_key)
           |> reject()
           |> json_response(404)

    assert story(ctx).agent_status == :reported_done
  end
end
