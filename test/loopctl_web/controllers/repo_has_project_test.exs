defmodule LoopctlWeb.RepoHasProjectTest do
  @moduledoc "US-52.1 (TC-52.1.5, TC-52.1.6): every route that could give a repo a second project answers 409."
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Projects

  @ssh "git@github.com:mkreyman/chg.git"
  @https "https://github.com/mkreyman/chg"

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    holder = fixture(:project, %{tenant_id: tenant.id, kind: :kb, slug: "chg", repo_url: @ssh})
    %{tenant: tenant, user_key: user_key, holder: holder}
  end

  defp assert_refused(conn, holder) do
    error = json_response(conn, 409)["error"]
    assert error["code"] == "repo_already_has_project"
    assert error["existing_project_id"] == holder.id
    assert error["message"] =~ "chg (#{holder.id})"
    assert error["message"] =~ "use that project"
  end

  test "POST /projects", %{conn: conn, user_key: key, holder: holder} do
    conn
    |> auth(key)
    |> post(~p"/api/v1/projects", %{"name" => "chg2", "slug" => "chg2", "repo_url" => @https})
    |> assert_refused(holder)
  end

  test "POST /kb-scopes", %{conn: conn, user_key: key, holder: holder} do
    conn
    |> auth(key)
    |> post(~p"/api/v1/kb-scopes", %{"name" => "chg3", "slug" => "chg3", "repo_url" => @https})
    |> assert_refused(holder)
  end

  test "PATCH /projects/:id", %{conn: conn, tenant: t, user_key: key, holder: holder} do
    other = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    conn
    |> auth(key)
    |> patch(~p"/api/v1/projects/#{other.id}", %{"repo_url" => @https})
    |> assert_refused(holder)
  end

  test "POST /projects/:id/restore", %{conn: conn, tenant: t, user_key: key, holder: holder} do
    {:ok, archived} =
      Projects.create_project(t.id, %{name: "old", slug: "old", repo_url: "mkreyman/elsewhere"})

    {:ok, archived} = Projects.archive_project(t.id, archived)
    {:ok, archived} = Projects.update_project(t.id, archived, %{repo_url: @https})

    conn
    |> auth(key)
    |> post(~p"/api/v1/projects/#{archived.id}/restore")
    |> assert_refused(holder)
  end

  test "POST /intake/sources", %{conn: conn, tenant: t, user_key: key, holder: holder} do
    work = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    conn
    |> auth(key)
    |> post(~p"/api/v1/intake/sources", %{
      "repo_full_name" => "mkreyman/chg",
      "project_id" => work.id
    })
    |> assert_refused(holder)
  end

  test "the OpenAPI spec documents the 409 on every refusing route", %{conn: conn} do
    paths = conn |> get("/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")

    for {path, verb} <- [
          {"/api/v1/projects", "post"},
          {"/api/v1/kb-scopes", "post"},
          {"/api/v1/projects/{id}", "patch"},
          {"/api/v1/projects/{id}/restore", "post"},
          {"/api/v1/kb-scopes/{id}/restore", "post"},
          {"/api/v1/intake/sources", "post"}
        ] do
      description = get_in(paths, [path, verb, "responses", "409", "description"])
      assert description =~ "repo_already_has_project", "#{verb} #{path}"
    end
  end

  test "PATCH /projects/:id under a live intake source for another repo answers 409 (#1082)",
       %{conn: conn, tenant: t, user_key: key} do
    project = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    {_secret, source} =
      fixture(:intake_source, %{
        tenant_id: t.id,
        project_id: project.id,
        repo_full_name: "acme/widgets"
      })

    error =
      conn
      |> auth(key)
      |> patch(~p"/api/v1/projects/#{project.id}", %{"repo_url" => "acme/infra"})
      |> json_response(409)
      |> Map.fetch!("error")

    assert error["code"] == "repo_held_by_intake_source"
    assert error["intake_source_id"] == source.id
    assert error["message"] =~ "acme/widgets"
    assert error["message"] =~ "Revoke that source first"
  end

  test "DELETE /projects/:id under a live intake source answers 409 (#1082)",
       %{conn: conn, tenant: t, user_key: key} do
    project = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    {_secret, source} =
      fixture(:intake_source, %{
        tenant_id: t.id,
        project_id: project.id,
        repo_full_name: "acme/widgets"
      })

    error =
      conn
      |> auth(key)
      |> delete(~p"/api/v1/projects/#{project.id}")
      |> json_response(409)
      |> Map.fetch!("error")

    assert error["code"] == "repo_held_by_intake_source"
    assert error["intake_source_id"] == source.id
    assert error["message"] =~ "cannot be archived"
  end
end
