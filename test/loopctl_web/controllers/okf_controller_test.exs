defmodule LoopctlWeb.OKFControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp user_key(tenant), do: fixture(:api_key, %{tenant_id: tenant.id, role: :user}) |> elem(0)

  defp published(tenant_id, attrs) do
    fixture(
      :article,
      Map.merge(%{tenant_id: tenant_id, status: :published}, Enum.into(attrs, %{}))
    )
  end

  describe "GET /api/v1/knowledge/okf/export" do
    test "returns a streamed .tar.gz archive by default", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)
      published(tenant.id, %{title: "Zip Article", category: :pattern})

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/gzip"

      assert {"content-disposition", cd} =
               List.keyfind(conn.resp_headers, "content-disposition", 0)

      assert cd =~ "okf-bundle-"
      assert cd =~ ".tar.gz"

      # The chunked tar.gz extracts to a valid OKF bundle (root index + concept).
      # Concept paths are id-suffixed (`pattern/zip-article-<short_id>.md`).
      assert {:ok, files} = Loopctl.StreamingExportHelper.extract(conn.resp_body)
      assert Map.has_key?(files, "index.md")
      assert Enum.any?(Map.keys(files), &String.starts_with?(&1, "pattern/zip-article-"))
    end

    test "format=json returns the files map and meta", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)
      published(tenant.id, %{title: "Json Article", category: :reference, tags: ["hub"]})

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export?format=json")

      body = json_response(conn, 200)
      assert body["data"]["meta"]["okf_version"] == "0.1"
      assert body["data"]["meta"]["article_count"] == 1
      assert Map.has_key?(body["data"]["files"], "index.md")
      assert Map.has_key?(body["data"]["files"], "reference/json-article.md")
    end

    test "format=json over the buffered-export cap returns 413 (no OOM regression)", %{conn: conn} do
      # The buffered json path materializes the whole bundle, so it is capped (test
      # cap is 2). A KB above it must 413 and point to the streamed .tar.gz, NOT
      # OOM by materializing everything.
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      for i <- 1..3 do
        published(tenant.id, %{title: "Big #{i}", category: :reference})
      end

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export?format=json")

      body = json_response(conn, 413)
      assert body["error"]["code"] == "payload_too_large"
      assert body["error"]["message"] =~ ".tar.gz"
    end

    test "the streamed .tar.gz default has NO count cap (exports above the json cap)", %{
      conn: conn
    } do
      # The same over-cap corpus streams fine as tar.gz (the backup path is
      # bounded-memory, not count-capped).
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      for i <- 1..3 do
        published(tenant.id, %{title: "Streamed #{i}", category: :reference})
      end

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export")

      assert conn.status == 200
      assert {:ok, files} = Loopctl.StreamingExportHelper.extract(conn.resp_body)

      concept_count =
        files
        |> Map.keys()
        |> Enum.count(&(String.ends_with?(&1, ".md") and not String.ends_with?(&1, "index.md")))

      assert concept_count == 3
    end

    test "requires user role (agent is forbidden)", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(agent_raw)
        |> get(~p"/api/v1/knowledge/okf/export")

      assert json_response(conn, 403)
    end

    test "unauthenticated returns 401", %{conn: conn} do
      assert conn |> get(~p"/api/v1/knowledge/okf/export") |> json_response(401)
    end
  end

  describe "POST /api/v1/knowledge/okf/import" do
    defp sample_files do
      %{
        "reference/imported.md" =>
          "---\ntype: reference\ntitle: Imported Doc\ntags:\n- okf\n---\n\nimported body\n",
        "index.md" => "# Bundle\n\n* [Imported Doc](reference/imported.md)\n"
      }
    end

    test "imports a bundle and returns a report", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{files: sample_files()})

      body = json_response(conn, 200)
      assert body["data"]["created"] == 1
      assert body["data"]["errors"] == []
      assert body["data"]["conformance"]["conformant"] == true

      %{data: [a]} = Knowledge.list_articles(tenant.id, category: :reference)
      assert a.title == "Imported Doc"
      assert a.tags == ["okf"]
    end

    test "dry_run reports without writing", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{files: sample_files(), dry_run: true})

      body = json_response(conn, 200)
      assert body["data"]["created"] == 1
      assert %{meta: %{total_count: 0}} = Knowledge.list_articles(tenant.id, category: :reference)
    end

    test "missing files returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{})

      assert json_response(conn, 400)["error"]["message"] =~ "files"
    end

    test "non-string file contents returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{files: %{"x.md" => 123}})

      assert json_response(conn, 400)
    end

    test "requires user role (agent is forbidden)", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(agent_raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{files: sample_files()})

      assert json_response(conn, 403)
    end

    test "import lands only in the caller's tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      raw = user_key(tenant)

      conn
      |> auth_conn(raw)
      |> post(~p"/api/v1/knowledge/okf/import", %{files: sample_files()})
      |> json_response(200)

      assert %{meta: %{total_count: 1}} = Knowledge.list_articles(tenant.id, category: :reference)
      assert %{meta: %{total_count: 0}} = Knowledge.list_articles(other.id, category: :reference)
    end
  end

  describe "OKF project_id validation (kbweb-01)" do
    test "export ?format=json with a malformed project_id returns 422, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export?format=json&project_id=not-a-uuid")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "streamed export with a malformed project_id returns 422 before committing a 200", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export?project_id=not-a-uuid")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "the project-scoped export path with a malformed project_id returns 422", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> get("/api/v1/projects/not-a-uuid/knowledge/okf/export")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "export ?format=json with a valid project_id still works (200)", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      published(tenant.id, %{title: "Scoped OKF", category: :pattern, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw)
        |> get(~p"/api/v1/knowledge/okf/export?format=json&project_id=#{project.id}")

      body = json_response(conn, 200)
      assert is_map(body["data"]["files"])
    end

    test "import with a malformed project_id returns 422, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)

      conn =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{
          files: sample_files(),
          project_id: "not-a-uuid"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "import with a valid project_id still works (200)", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = user_key(tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/knowledge/okf/import", %{files: sample_files(), project_id: project.id})

      assert json_response(conn, 200)["data"]["created"] == 1
    end
  end
end
