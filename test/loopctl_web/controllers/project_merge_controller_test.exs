defmodule LoopctlWeb.ProjectMergeControllerTest do
  @moduledoc "US-52.2 (TC-52.2.7): POST /api/v1/projects/:id/merge_into, its gates and bodies."
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Projects.Project

  import Ecto.Query, only: [from: 2]

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    work = fixture(:project, %{tenant_id: tenant.id, repo_url: nil})
    kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb})
    %{tenant: tenant, work: work, kb: kb}
  end

  defp key(tenant, role), do: elem(fixture(:api_key, %{tenant_id: tenant.id, role: role}), 0)

  test "a user key merges and gets the result", %{conn: conn, tenant: t, work: work, kb: kb} do
    body =
      conn
      |> auth(key(t, :user))
      |> post(~p"/api/v1/projects/#{work.id}/merge_into", %{"target_project_id" => kb.id})
      |> json_response(200)

    assert body["merge"]["promoted"] == true
    assert body["merge"]["target_id"] == kb.id
    assert %{status: :archived} = AdminRepo.get!(Project, work.id)
  end

  test "dry_run writes nothing", %{conn: conn, tenant: t, work: work, kb: kb} do
    body =
      conn
      |> auth(key(t, :user))
      |> post(~p"/api/v1/projects/#{work.id}/merge_into", %{
        "target_project_id" => kb.id,
        "dry_run" => true
      })
      |> json_response(200)

    assert body["merge"]["dry_run"] == true
    assert %{status: :active} = AdminRepo.get!(Project, work.id)
  end

  test "orchestrator and agent keys are refused 403", %{conn: conn, tenant: t, work: work, kb: kb} do
    for role <- [:orchestrator, :agent] do
      conn
      |> auth(key(t, role))
      |> post(~p"/api/v1/projects/#{work.id}/merge_into", %{"target_project_id" => kb.id})
      |> json_response(403)
    end

    assert %{status: :active} = AdminRepo.get!(Project, work.id)
  end

  test "an agent-rooted tenant is refused by the human-anchor gate", %{conn: conn} do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
    a = fixture(:project, %{tenant_id: tenant.id})
    b = fixture(:project, %{tenant_id: tenant.id})

    conn
    |> auth(key(tenant, :user))
    |> post(~p"/api/v1/projects/#{a.id}/merge_into", %{"target_project_id" => b.id})
    |> json_response(403)
  end

  test "conflicting rows answer 409 merge_conflicts", %{conn: conn, tenant: t, work: work, kb: kb} do
    fixture(:story, %{tenant_id: t.id, project_id: work.id, number: "1.1"})
    other = fixture(:project, %{tenant_id: t.id})
    fixture(:story, %{tenant_id: t.id, project_id: other.id, number: "1.1"})
    _ = kb

    error =
      conn
      |> auth(key(t, :user))
      |> post(~p"/api/v1/projects/#{work.id}/merge_into", %{"target_project_id" => other.id})
      |> json_response(409)
      |> Map.fetch!("error")

    assert error["code"] == "merge_conflicts"
    assert [%{"table" => "stories"} | _] = error["conflicts"]
  end

  test "same project is 422; a foreign target is 404", %{conn: conn, tenant: t, work: work} do
    user = key(t, :user)

    conn
    |> auth(user)
    |> post(~p"/api/v1/projects/#{work.id}/merge_into", %{"target_project_id" => work.id})
    |> json_response(422)

    conn
    |> auth(user)
    |> post(~p"/api/v1/projects/#{work.id}/merge_into", %{
      "target_project_id" => fixture(:project).id
    })
    |> json_response(404)
  end

  test "a source whose live intake source names another repo is refused 409 (#1113)",
       %{conn: conn, tenant: t} do
    source_project = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    {_secret, source} =
      fixture(:intake_source, %{
        tenant_id: t.id,
        project_id: source_project.id,
        repo_full_name: "acme/widgets"
      })

    target = fixture(:project, %{tenant_id: t.id, repo_url: "acme/infra"})

    error =
      conn
      |> auth(key(t, :user))
      |> post(~p"/api/v1/projects/#{source_project.id}/merge_into", %{
        "target_project_id" => target.id
      })
      |> json_response(409)
      |> Map.fetch!("error")

    assert error["code"] == "merge_strands_intake_source"
    assert error["intake_source_id"] == source.id
    assert %{status: :active} = AdminRepo.get!(Project, source_project.id)
  end

  test "a repo-less target that would claim a held repo is refused 409 (#1113)",
       %{conn: conn, tenant: t} do
    source_project = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    fixture(:intake_source, %{
      tenant_id: t.id,
      project_id: source_project.id,
      repo_full_name: "acme/widgets"
    })

    AdminRepo.update_all(
      from(p in Project, where: p.id == ^source_project.id),
      set: [repo_url: nil, repo_key: nil]
    )

    holder = fixture(:project, %{tenant_id: t.id, repo_url: "acme/widgets"})
    target = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    error =
      conn
      |> auth(key(t, :user))
      |> post(~p"/api/v1/projects/#{source_project.id}/merge_into", %{
        "target_project_id" => target.id
      })
      |> json_response(409)
      |> Map.fetch!("error")

    assert error["code"] == "repo_already_has_project"
    assert error["existing_project_id"] == holder.id
  end
end
