defmodule LoopctlWeb.Plugs.ResolveProjectRefTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias LoopctlWeb.Helpers.ProjectId
  alias LoopctlWeb.Plugs.ResolveProjectRef

  defp keyed(conn, tenant_id) do
    assign(conn, :current_api_key, %ApiKey{tenant_id: tenant_id, role: :agent})
  end

  describe "call/2" do
    test "resolves an exact project slug to that project's UUID", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id, slug: "home-care-billing")

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "home-care-billing", "q" => "rls"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == project.id
      # Untouched neighbours: the plug rewrites one key, not the param map.
      assert conn.params["q"] == "rls"
      # The whole point: what the plug produced now clears the 422 gate.
      assert ProjectId.validate(conn.params["project_id"]) == :ok
    end

    test "resolves a slug carried in the ROUTE, not just the query string", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id, slug: "loopctl")

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "loopctl"})
        |> Map.put(:path_params, %{"project_id" => "loopctl"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == project.id
      assert conn.path_params["project_id"] == project.id
    end

    test "leaves path_params alone when the route matched a DIFFERENT value", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id, slug: "loopctl")
      story_id = Ecto.UUID.generate()

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "loopctl", "id" => story_id})
        |> Map.put(:path_params, %{"id" => story_id})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == project.id
      assert conn.path_params == %{"id" => story_id}
    end

    test "a canonical UUID is passed through untouched", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id, slug: "loopctl")

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => project.id})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == project.id
    end

    test "an unresolvable value is left alone, so the 422 still fires", %{conn: conn} do
      tenant = fixture(:tenant)

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "no_such_project"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == "no_such_project"
      assert {:error, :unprocessable_entity, _} = ProjectId.validate(conn.params["project_id"])
    end

    test "another tenant's slug does NOT resolve (no cross-tenant oracle)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _theirs = fixture(:project, tenant_id: tenant_b.id, slug: "their-secret-repo")

      conn =
        conn
        |> keyed(tenant_a.id)
        |> Map.put(:params, %{"project_id" => "their-secret-repo"})
        |> ResolveProjectRef.call([])

      # Byte-identical to the typo case above: a foreign slug and a nonexistent one
      # are indistinguishable to the caller.
      assert conn.params["project_id"] == "their-secret-repo"
    end

    test "a superadmin key (no tenant) is skipped", %{conn: conn} do
      tenant = fixture(:tenant)
      _project = fixture(:project, tenant_id: tenant.id, slug: "loopctl")

      conn =
        conn
        |> assign(:current_api_key, %ApiKey{tenant_id: nil, role: :superadmin})
        |> Map.put(:params, %{"project_id" => "loopctl"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == "loopctl"
    end

    test "an unauthenticated conn is skipped without a lookup", %{conn: conn} do
      tenant = fixture(:tenant)
      _project = fixture(:project, tenant_id: tenant.id, slug: "loopctl")

      conn =
        conn
        |> Map.put(:params, %{"project_id" => "loopctl"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == "loopctl"
    end

    test "an empty or non-binary project_id is untouched", %{conn: conn} do
      tenant = fixture(:tenant)

      for value <- ["", ["a", "b"], 123] do
        conn =
          conn
          |> keyed(tenant.id)
          |> Map.put(:params, %{"project_id" => value})
          |> ResolveProjectRef.call([])

        assert conn.params["project_id"] == value
      end
    end

    test "a conn with no project_id param at all is untouched", %{conn: conn} do
      tenant = fixture(:tenant)

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"q" => "rls"})
        |> ResolveProjectRef.call([])

      refute Map.has_key?(conn.params, "project_id")
    end

    test "resolves the repo DIRECTORY name agents actually type (home_care_billing)",
         %{conn: conn} do
      # The measured case, x24: the underscored checkout directory, against a
      # hyphenated slug. Neither get_project_by_slug/2 nor resolve_project/2 answers it.
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id, slug: "home-care-billing")

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "home_care_billing"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == project.id
    end

    test "resolves by repo BASENAME when the slug has drifted from the repo",
         %{conn: conn} do
      tenant = fixture(:tenant)

      project =
        fixture(:project,
          tenant_id: tenant.id,
          slug: "freight-pilot-2",
          repo_url: "https://github.com/mkreyman/freight-pilot"
        )

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "freight_pilot"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == project.id
    end

    test "an AMBIGUOUS repo basename is left alone rather than guessing", %{conn: conn} do
      tenant = fixture(:tenant)

      _one =
        fixture(:project,
          tenant_id: tenant.id,
          slug: "api-a",
          repo_url: "https://github.com/acme/api"
        )

      _two =
        fixture(:project,
          tenant_id: tenant.id,
          slug: "api-b",
          repo_url: "https://gitlab.com/other/api"
        )

      conn =
        conn
        |> keyed(tenant.id)
        |> Map.put(:params, %{"project_id" => "api"})
        |> ResolveProjectRef.call([])

      assert conn.params["project_id"] == "api"
    end

    test "emits [:loopctl, :project_id, :ref_resolved] on a rescue", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id, slug: "loopctl")

      :telemetry.attach(
        "resolve-project-ref-test",
        Loopctl.TelemetryEvents.project_ref_resolved(),
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("resolve-project-ref-test") end)

      conn
      |> keyed(tenant.id)
      |> Map.put(:params, %{"project_id" => "loopctl"})
      |> ResolveProjectRef.call([])

      assert_receive {:telemetry, [:loopctl, :project_id, :ref_resolved], %{count: 1}, metadata}
      assert metadata.ref == "loopctl"
      assert metadata.matched_by == :slug
      assert metadata.project_id == project.id
      assert metadata.tenant_id == tenant.id
    end
  end
end
