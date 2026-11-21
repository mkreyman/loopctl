defmodule LoopctlWeb.StoryHolderFieldsTest do
  @moduledoc """
  US-52.20: the reads a client needs to tell two sessions of one agent apart — the story's
  `assigned_holder_id`, `claim_epoch` and `claimed_until`, `get_story`'s `assigned_holder`,
  and the stage read's `runner_name`.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Holders
  alias Loopctl.WorkBreakdown.Story

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp held_story do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw_key, _api_key, agent} = fixture(:agent_key, %{tenant_id: tenant.id})

    {:ok, %{holder: holder}} =
      Holders.register(tenant.id, agent.id, %{
        "kind" => "interactive",
        "session_id" => "s-#{System.unique_integer([:positive])}",
        "host" => "minis"
      })

    story = fixture(:ledger_story, %{tenant_id: tenant.id})

    {1, _} =
      AdminRepo.update_all(
        from(s in Story, where: s.id == ^story.id),
        set: [
          assigned_agent_id: agent.id,
          assigned_holder_id: holder.id,
          agent_status: :implementing,
          claim_epoch: 3,
          claimed_until: holder.lease_until
        ]
      )

    %{tenant: tenant, raw_key: raw_key, story: story, holder: holder}
  end

  test "get_story names the holder, the epoch and the lease; never a credential", %{conn: conn} do
    %{raw_key: raw_key, story: story, holder: holder} = held_story()

    body = conn |> auth(raw_key) |> get(~p"/api/v1/stories/#{story.id}") |> json_response(200)

    assert body["story"]["assigned_holder_id"] == holder.id
    assert body["story"]["claim_epoch"] == 3
    assert body["story"]["claimed_until"] == DateTime.to_iso8601(holder.lease_until)

    assert %{"id" => id, "kind" => "interactive", "host" => "minis", "session_id" => sid} =
             body["story"]["assigned_holder"]

    assert id == holder.id and sid == holder.session_id

    assert Map.keys(body["story"]["assigned_holder"]) |> Enum.sort() ==
             ~w(ended_at ended_reason host id kind lease_until session_id)
  end

  test "an unheld story answers assigned_holder null", %{conn: conn} do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw_key, _api_key, _agent} = fixture(:agent_key, %{tenant_id: tenant.id})
    story = fixture(:ledger_story, %{tenant_id: tenant.id})

    body = conn |> auth(raw_key) |> get(~p"/api/v1/stories/#{story.id}") |> json_response(200)

    assert body["story"]["assigned_holder_id"] == nil
    assert body["story"]["assigned_holder"] == nil
  end

  test "the story list carries assigned_holder_id too", %{conn: conn} do
    %{raw_key: raw_key, story: story, holder: holder} = held_story()

    body =
      conn
      |> auth(raw_key)
      |> get(~p"/api/v1/stories?project_id=#{story.project_id}")
      |> json_response(200)

    assert [%{"assigned_holder_id" => id, "claim_epoch" => 3}] =
             Enum.filter(body["data"], &(&1["id"] == story.id))

    assert id == holder.id
  end

  test "the stage read names its runner", %{conn: conn} do
    %{tenant: tenant, raw_key: raw_key, story: story} = held_story()
    {_runner_key, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "x1"})

    fixture(:story_stage, %{
      repo: AdminRepo,
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :implementing,
      claim_epoch: 3,
      runner_id: runner.id
    })

    body =
      conn |> auth(raw_key) |> get(~p"/api/v1/stories/#{story.id}/stage") |> json_response(200)

    assert body["stage"]["runner_id"] == runner.id
    assert body["stage"]["runner_name"] == "x1"
  end

  test "tenant isolation: another tenant's key cannot read the holder", %{conn: conn} do
    %{story: story} = held_story()
    other = fixture(:tenant, %{trust_tier: :human_anchored})
    {other_key, _api_key, _agent} = fixture(:agent_key, %{tenant_id: other.id})

    assert conn |> auth(other_key) |> get(~p"/api/v1/stories/#{story.id}") |> json_response(404)
  end
end
