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

  # US-27.16: concept paths are id-suffixed (`{category}/{slug}-{short_id}.md`), so
  # match on the `{category}/{slug}-` PREFIX (the suffix varies per run).
  defp has_slug?(file_map, "" <> category_slug),
    do: Enum.any?(Map.keys(file_map), &String.starts_with?(&1, category_slug <> "-"))

  defp fetch_slug(file_map, "" <> category_slug) do
    {_path, content} =
      Enum.find(file_map, fn {path, _} -> String.starts_with?(path, category_slug <> "-") end)

    content
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
      assert has_slug?(file_map, "pattern/ecto-multi-pattern")
      assert has_slug?(file_map, "convention/naming-convention")

      # Verify YAML frontmatter in pattern article
      pattern_content = fetch_slug(file_map, "pattern/ecto-multi-pattern")
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
      source_content = fetch_slug(file_map, "pattern/source-article")
      assert source_content =~ "## Related Articles"
      assert source_content =~ "[[Target Article]] (relates_to)"

      # Target article should have incoming link
      target_content = fetch_slug(file_map, "decision/target-article")
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
      assert has_slug?(file_map, "pattern/published-one")
      refute has_slug?(file_map, "pattern/draft-article")
      refute has_slug?(file_map, "decision/archived-article")
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
    test "returns 429 when the REQUEST tenant's in-flight export cap is already met", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Saturate the PER-TENANT cap for THIS tenant (default 1) by holding a slot for
      # `tenant.id` in a kept-alive process. The export request below is for the same
      # tenant, so it trips the per-tenant cap and is refused 429 BEFORE streaming —
      # deterministically, and WITHOUT depending on the shared global counter's exact
      # value (which other async tests transiently touch). This proves the cap path
      # rejects with 429 + Retry-After off the admin pool.
      holder = hold_tenant_slot(tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      body = json_response(conn, 429)
      assert body["error"]["code"] == "too_many_exports"
      assert [_] = get_resp_header(conn, "retry-after")

      release_slot(holder)
    end

    # Hold a slot for a SPECIFIC tenant (to saturate its per-tenant cap). Retries on
    # transient global contention from concurrent async tests.
    defp hold_tenant_slot(tenant_id) do
      parent = self()

      pid =
        spawn(fn ->
          :ok = acquire_with_retry(tenant_id, 200)
          send(parent, {:held, self()})

          receive do
            :release -> ExportConcurrency.release(tenant_id)
          end
        end)

      receive do
        {:held, ^pid} -> pid
      after
        5_000 -> raise "failed to hold per-tenant export slot"
      end
    end

    defp acquire_with_retry(_t, 0), do: raise("could not acquire an export slot")

    defp acquire_with_retry(t, attempts) do
      case ExportConcurrency.acquire(t) do
        :ok ->
          :ok

        {:error, :too_many_exports} ->
          Process.sleep(10)
          acquire_with_retry(t, attempts - 1)
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
      assert has_slug?(file_map, "pattern/tenant-wide-pattern")
      assert has_slug?(file_map, "convention/project-convention")
      refute has_slug?(file_map, "finding/other-project-finding")
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
      assert has_slug?(file_map, "pattern/tenant-a-article")
      refute has_slug?(file_map, "pattern/tenant-b-article")

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
      assert Enum.any?(
               filenames,
               &String.starts_with?(&1, "decision/whats-new-v20-breaking-changes-")
             )
    end
  end

  describe "GET /api/v1/knowledge/export project_id validation (kbweb-01)" do
    test "a malformed project_id returns 422 BEFORE any chunked body commits a 200", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export", %{project_id: "not-a-uuid"})

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] =~ "project_id"
    end

    test "a valid project_id streams a 200 archive scoped to that project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Scoped Export Pattern",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export", %{project_id: project.id})

      assert conn.status == 200
      files = export_files(conn)
      assert has_slug?(files, "pattern/scoped-export-pattern")
    end

    test "an absent project_id streams a 200 tenant-wide archive", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide Export",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/export")

      assert conn.status == 200
      files = export_files(conn)
      assert has_slug?(files, "pattern/tenant-wide-export")
    end

    test "the project-scoped path with a malformed project_id returns 422", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/projects/not-a-uuid/knowledge/export")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end
  end
end
