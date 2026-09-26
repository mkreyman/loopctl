defmodule LoopctlWeb.ThreadControllerTest do
  @moduledoc """
  US-45.1: the thread endpoints. The fence, the idempotency and the reference rules are tested
  without a socket in `Loopctl.ThreadsTest`; this module pins the HTTP surface — the role
  gates, the status codes and the untrusted marker.

  `async: false` for the reason `StoryEscalationControllerTest` gives: the key is resolved on
  `AdminRepo` and the story lives on the RLS `Repo`, so the tenant and the key are committed.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 4
  @sha String.duplicate("d", 40)
  @tree String.duplicate("e", 40)

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp claimed_story do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw_key, _api_key, agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    {operator_key, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: @epoch})

    {:ok, _} =
      Repo.with_tenant(tenant.id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [assigned_agent_id: agent.id, agent_status: :implementing])
      end)

    %{story: story, raw_key: raw_key, operator_key: operator_key}
  end

  defp post_checkpoint(conn, key, story, body) do
    conn |> auth(key) |> post(~p"/api/v1/stories/#{story.id}/thread/checkpoints", body)
  end

  @checkpoint %{"claim_epoch" => @epoch, "commit_sha" => @sha, "tree_sha" => @tree}

  test "the claimant records a checkpoint: 201, then 200 on a resend", %{conn: conn} do
    %{story: story, raw_key: key} = claimed_story()

    assert %{"checkpoint" => %{"seq" => 1, "commit_sha" => @sha}} =
             conn |> post_checkpoint(key, story, @checkpoint) |> json_response(201)

    assert %{"checkpoint" => %{"seq" => 1}} =
             build_conn() |> post_checkpoint(key, story, @checkpoint) |> json_response(200)
  end

  test "a checkpoint needs an agent key and the current epoch", %{conn: conn} do
    %{story: story, raw_key: key, operator_key: operator} = claimed_story()

    assert conn |> post_checkpoint(operator, story, @checkpoint) |> json_response(403)

    assert %{"error" => %{"code" => "stale_claim_epoch"}} =
             build_conn()
             |> post_checkpoint(key, story, %{@checkpoint | "claim_epoch" => @epoch - 1})
             |> json_response(409)

    assert build_conn()
           |> post_checkpoint(key, story, Map.delete(@checkpoint, "claim_epoch"))
           |> json_response(400)
  end

  test "any principal writes a message; the thread marks bodies untrusted", %{conn: conn} do
    %{story: story, raw_key: key, operator_key: operator} = claimed_story()

    entry = %{"kind" => "message", "idempotency_key" => "m1", "body" => "looks right"}

    assert conn
           |> auth(operator)
           |> post(~p"/api/v1/stories/#{story.id}/thread/entries", entry)
           |> json_response(201)

    assert %{"entries" => [%{"body" => "looks right", "body_untrusted" => true}]} =
             build_conn()
             |> auth(key)
             |> get(~p"/api/v1/stories/#{story.id}/thread")
             |> json_response(200)
  end

  test "a lapsed lease is 409 claim_not_live", %{conn: conn} do
    %{story: story, raw_key: key} = claimed_story()

    {:ok, _} =
      Repo.with_tenant(story.tenant_id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60)])
      end)

    assert %{"error" => %{"code" => "claim_not_live"}} =
             conn |> post_checkpoint(key, story, @checkpoint) |> json_response(409)
  end

  test "a malformed or out-of-range page parameter is 400", %{conn: conn} do
    %{story: story, raw_key: key} = claimed_story()

    assert conn
           |> auth(key)
           |> get(~p"/api/v1/stories/#{story.id}/thread?limit=lots")
           |> json_response(400)

    assert build_conn()
           |> auth(key)
           |> get(~p"/api/v1/stories/#{story.id}/thread?after_seq=99999999999")
           |> json_response(400)
  end

  test "a key reused for a different entry is 409 idempotency_key_reused", %{conn: conn} do
    %{story: story, raw_key: key} = claimed_story()
    path = ~p"/api/v1/stories/#{story.id}/thread/entries"
    entry = %{"kind" => "message", "idempotency_key" => "k", "body" => "first"}

    assert conn |> auth(key) |> post(path, entry) |> json_response(201)

    assert %{"error" => %{"code" => "idempotency_key_reused"}} =
             build_conn()
             |> auth(key)
             |> post(path, %{entry | "body" => "second"})
             |> json_response(409)
  end

  test "a finding is not writable here: 422, pointing at the review dispatch", %{conn: conn} do
    %{story: story, raw_key: key} = claimed_story()
    finding = %{"kind" => "finding", "idempotency_key" => "f", "body" => "x"}

    assert %{"error" => %{"message" => msg}} =
             conn
             |> auth(key)
             |> post(~p"/api/v1/stories/#{story.id}/thread/entries", finding)
             |> json_response(422)

    assert msg =~ "review dispatch"
  end

  test "an unknown or malformed story id is 404", %{conn: conn} do
    %{raw_key: key} = claimed_story()

    assert conn |> auth(key) |> get(~p"/api/v1/stories/not-a-uuid/thread") |> json_response(404)

    assert build_conn()
           |> auth(key)
           |> get(~p"/api/v1/stories/#{Ecto.UUID.generate()}/thread")
           |> json_response(404)
  end
end
