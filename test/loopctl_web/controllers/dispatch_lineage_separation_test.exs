defmodule LoopctlWeb.SiblingDispatchReportTest do
  @moduledoc """
  Regression probe: two agents dispatched by the SAME orchestrator share a lineage
  ROOT. After #621 records implementer_dispatch_id at claim, the lineage gate goes
  live — does a sibling reviewer still get to report?
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp actor(tenant, role, lineage) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw_key, api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: role, agent_id: agent.id})

    d =
      %Dispatch{tenant_id: tenant.id}
      |> Dispatch.changeset(%{
        role: role,
        agent_id: agent.id,
        api_key_id: api_key.id,
        lineage_path: lineage,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> AdminRepo.insert!()

    %{agent: agent, raw_key: raw_key, dispatch: d, lineage: lineage}
  end

  test "a SIBLING agent under the same orchestrator root can report", %{conn: conn} do
    tenant = fixture(:tenant)
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    tenant = tenant |> Ecto.Changeset.change(audit_signing_public_key: pub) |> AdminRepo.update!()
    Mox.stub(Loopctl.MockSecrets, :get, fn _ -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        agent_status: :contracted
      })

    # ONE orchestrator root, two children — the normal dispatch shape.
    root = Ecto.UUID.generate()
    impl = actor(tenant, :agent, [root, Ecto.UUID.generate()])
    reviewer = actor(tenant, :agent, [root, Ecto.UUID.generate()])

    %{"capability" => cap} =
      conn
      |> auth(impl.raw_key)
      |> post("/api/v1/stories/#{story.id}/claim")
      |> json_response(200)

    conn
    |> auth(impl.raw_key)
    |> post("/api/v1/stories/#{story.id}/start", %{"capability" => cap["cap_id"]})
    |> json_response(200)

    resp =
      conn
      |> auth(reviewer.raw_key)
      |> post("/api/v1/stories/#{story.id}/report", %{"summary" => "reviewed"})

    assert resp.status == 200,
           "a sibling reviewer under the same orchestrator root got #{resp.status}: #{resp.resp_body}"
  end
end
