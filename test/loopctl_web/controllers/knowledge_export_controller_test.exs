defmodule LoopctlWeb.KnowledgeExportControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Knowledge.ExportConcurrency

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # US-27.16: the export is now a streamed `.tar.gz`. Under the inline ConnTest
  # transport `send_chunked` buffers chunks into `resp_body`, so the full archive is
  # `conn.resp_body`; unpack it as tar.gz.
  defp export_files(conn) do
    {:ok, files} = Loopctl.StreamingExportHelper.extract(conn.resp_body)
    files
  end

  describe "GET /api/v1/knowledge/export" do
    test "exports published articles as ZIP with correct structure and frontmatter", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published,
        tags: ["ecto", "transactions"],
        source_type: "review_finding"
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Naming Convention",
        body: "Use snake_case for functions.",
        category: :convention,
        status: :published,
        tags: ["naming"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/gzip"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename=\"knowledge-export-"
      assert disposition =~ ".tar.gz\""

      # Unzip and verify contents
      file_map = export_files(conn)

      # Verify directory structure
      assert Map.has_key?(file_map, "_index.md")
      assert Map.has_key?(file_map, "pattern/ecto-multi-pattern.md")
      assert Map.has_key?(file_map, "convention/naming-convention.md")

      # Verify YAML frontmatter in pattern article
      pattern_content = file_map["pattern/ecto-multi-pattern.md"]
      assert pattern_content =~ "---\n"
      assert pattern_content =~ ~s(title: "Ecto Multi Pattern")
      assert pattern_content =~ "category: pattern"
      assert pattern_content =~ "tags:"
      assert pattern_content =~ "  - ecto"
      assert pattern_content =~ "  - transactions"
      assert pattern_content =~ "status: published"
      assert pattern_content =~ "source_type: review_finding"
      assert pattern_content =~ "created_at:"
      assert pattern_content =~ "updated_at:"

      # Verify body content
      assert pattern_content =~ "Use Ecto.Multi for atomic operations."

      # Verify index file
      # US-27.16: `_index.md` is built from a CHEAP per-category COUNT aggregate
      # (no bodies loaded), so it lists categories with counts, not every title.
      index_content = file_map["_index.md"]
      assert index_content =~ "# Knowledge Base Index"
      assert index_content =~ "## Convention"
      assert index_content =~ "## Pattern"
      assert index_content =~ "1 article(s)"
    end

    test "includes related articles as wikilinks", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      source =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Source Article",
          body: "Source body.",
          category: :pattern,
          status: :published
        })

      target =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Target Article",
          body: "Target body.",
          category: :decision,
          status: :published
        })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: source.id,
        target_article_id: target.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200

      file_map = export_files(conn)

      # Source article should have outgoing link
      source_content = file_map["pattern/source-article.md"]
      assert source_content =~ "## Related Articles"
      assert source_content =~ "[[Target Article]] (relates_to)"

      # Target article should have incoming link
      target_content = file_map["decision/target-article.md"]
      assert target_content =~ "## Related Articles"
      assert target_content =~ "[[Source Article]] (relates_to)"
    end

    test "excludes drafts, archived, and superseded articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published One",
        body: "Content.",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Article",
        body: "Draft.",
        category: :pattern,
        status: :draft
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Archived Article",
        body: "Archived.",
        category: :decision,
        status: :archived
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200

      file_map = export_files(conn)

      # Only published article + index
      assert map_size(file_map) == 2
      assert Map.has_key?(file_map, "_index.md")
      assert Map.has_key?(file_map, "pattern/published-one.md")
      refute Map.has_key?(file_map, "pattern/draft-article.md")
      refute Map.has_key?(file_map, "decision/archived-article.md")
    end

    test "returns ZIP with only _index.md when no published articles exist", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Only draft articles
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Only",
        body: "Not published.",
        category: :pattern,
        status: :draft
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/gzip"

      file_map = export_files(conn)

      assert map_size(file_map) == 1
      assert Map.has_key?(file_map, "_index.md")
      assert file_map["_index.md"] =~ "# Knowledge Base Index"
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/export")
      assert json_response(conn, 401)
    end

    test "agent role returns 403", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert json_response(conn, 403)
    end
  end

  describe "concurrency cap (AC-27.16.6)" do
    test "returns 429 when the global in-flight export cap is already met", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Saturate the GLOBAL cap (default 2) with two held slots from OTHER tenants
      # in separate, kept-alive processes (one slot per tenant respects the
      # per-tenant cap of 1). The request below should then be refused with 429,
      # BEFORE any streaming begins — never queued against the admin pool.
      holders = for _ <- 1..ExportConcurrency.max_global(), do: hold_slot()

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      body = json_response(conn, 429)
      assert body["error"]["code"] == "too_many_exports"
      assert [_] = get_resp_header(conn, "retry-after")

      Enum.each(holders, &release_slot/1)
    end

    defp hold_slot do
      parent = self()
      t = Ecto.UUID.generate()

      pid =
        spawn(fn ->
          :ok = ExportConcurrency.acquire(t)
          send(parent, {:held, self()})

          receive do
            :release -> ExportConcurrency.release(t)
          end
        end)

      receive do
        {:held, ^pid} -> pid
      after
        1_000 -> raise "failed to hold export slot"
      end
    end

    defp release_slot(pid), do: send(pid, :release)
  end

  describe "GET /api/v1/projects/:project_id/knowledge/export" do
    test "project-scoped export includes tenant-wide and project articles", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Tenant-wide article (nil project_id) -- should be included
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide Pattern",
        body: "Applies everywhere.",
        category: :pattern,
        status: :published
      })

      # Project-specific article -- should be included
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Project Convention",
        body: "Project specific.",
        category: :convention,
        status: :published
      })

      # Other project's article -- should be excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project Finding",
        body: "Different project.",
        category: :finding,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/knowledge/export")

      assert conn.status == 200

      file_map = export_files(conn)

      # Should have 2 articles + index = 3 files
      assert map_size(file_map) == 3
      assert Map.has_key?(file_map, "_index.md")
      assert Map.has_key?(file_map, "pattern/tenant-wide-pattern.md")
      assert Map.has_key?(file_map, "convention/project-convention.md")
      refute Map.has_key?(file_map, "finding/other-project-finding.md")
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's articles in export", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Article",
        body: "A content.",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Article",
        body: "B content.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200

      file_map = export_files(conn)

      # Should only contain tenant A's article
      assert map_size(file_map) == 2
      assert Map.has_key?(file_map, "pattern/tenant-a-article.md")
      refute Map.has_key?(file_map, "pattern/tenant-b-article.md")

      # No tenant B content leaks into ANY archive entry (BYPASSRLS scope proof).
      all_content = file_map |> Map.values() |> Enum.join("\n")
      assert all_content =~ "A content."
      refute all_content =~ "Tenant B Article"
      refute all_content =~ "B content."
    end
  end

  describe "filename sanitization" do
    test "special characters are removed from filenames", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "What's New? (v2.0) -- Breaking Changes!",
        body: "Details.",
        category: :decision,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200

      filenames = conn |> export_files() |> Map.keys()

      # Should have sanitized filename
      assert "decision/whats-new-v20-breaking-changes.md" in filenames
    end
  end
end
