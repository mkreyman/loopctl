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
      assert {:ok, files} = Loopctl.StreamingExportHelper.extract(conn.resp_body)
      assert Map.has_key?(files, "index.md")
      assert Map.has_key?(files, "pattern/zip-article.md")
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
end
