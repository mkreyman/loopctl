defmodule Loopctl.KnowledgeExportTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  describe "export_obsidian/2" do
    test "returns ZIP binary with published articles organized by category" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern One",
        body: "Pattern body.",
        category: :pattern,
        status: :published,
        tags: ["elixir"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Decision Alpha",
        body: "Decision body.",
        category: :decision,
        status: :published
      })

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant.id)
      assert is_binary(zip_binary)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      file_map = Map.new(files, fn {name, content} -> {to_string(name), content} end)

      assert map_size(file_map) == 3
      assert Map.has_key?(file_map, "_index.md")
      assert Map.has_key?(file_map, "pattern/pattern-one.md")
      assert Map.has_key?(file_map, "decision/decision-alpha.md")
    end

    test "excludes non-published articles" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published",
        body: "Pub.",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft",
        body: "Draft.",
        category: :pattern,
        status: :draft
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Archived",
        body: "Arch.",
        category: :convention,
        status: :archived
      })

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant.id)
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _} -> to_string(name) end)

      assert "_index.md" in filenames
      assert "pattern/published.md" in filenames
      refute "pattern/draft.md" in filenames
      refute "convention/archived.md" in filenames
    end

    test "scopes by project_id when provided" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})

      # Tenant-wide -- included
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Global",
        body: "G.",
        category: :pattern,
        status: :published
      })

      # Target project -- included
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "In Project",
        body: "P.",
        category: :convention,
        status: :published
      })

      # Other project -- excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project",
        body: "O.",
        category: :finding,
        status: :published
      })

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant.id, project_id: project.id)
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _} -> to_string(name) end)

      assert "pattern/global.md" in filenames
      assert "convention/in-project.md" in filenames
      refute "finding/other-project.md" in filenames
    end

    test "returns ZIP with only _index.md when no published articles" do
      tenant = fixture(:tenant)

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant.id)
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      file_map = Map.new(files, fn {name, content} -> {to_string(name), content} end)

      assert map_size(file_map) == 1
      assert Map.has_key?(file_map, "_index.md")
      assert file_map["_index.md"] =~ "# Knowledge Base Index"
    end

    test "tenant isolation -- other tenant's articles excluded" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "A Article",
        body: "A.",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "B Article",
        body: "B.",
        category: :pattern,
        status: :published
      })

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant_a.id)
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _} -> to_string(name) end)

      assert "pattern/a-article.md" in filenames
      refute "pattern/b-article.md" in filenames
    end

    test "YAML frontmatter includes all required fields" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Full Article",
        body: "The full body content.",
        category: :finding,
        status: :published,
        tags: ["tag1", "tag2"],
        source_type: "manual"
      })

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant.id)
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      file_map = Map.new(files, fn {name, content} -> {to_string(name), content} end)

      content = file_map["finding/full-article.md"]

      assert content =~ ~s(title: "Full Article")
      assert content =~ "category: finding"
      assert content =~ "tags:\n  - tag1\n  - tag2"
      assert content =~ "status: published"
      assert content =~ "source_type: manual"
      assert content =~ "created_at:"
      assert content =~ "updated_at:"
      assert content =~ "The full body content."
    end

    test "related articles rendered as wikilinks with link types" do
      tenant = fixture(:tenant)

      source =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Source",
          body: "Source body.",
          category: :pattern,
          status: :published
        })

      target =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Target",
          body: "Target body.",
          category: :decision,
          status: :published
        })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: source.id,
        target_article_id: target.id,
        relationship_type: :contradicts
      })

      {:ok, zip_binary} = Knowledge.export_obsidian(tenant.id)
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      file_map = Map.new(files, fn {name, content} -> {to_string(name), content} end)

      source_md = file_map["pattern/source.md"]
      assert source_md =~ "## Related Articles"
      assert source_md =~ "[[Target]] (contradicts)"

      target_md = file_map["decision/target.md"]
      assert target_md =~ "## Related Articles"
      assert target_md =~ "[[Source]] (contradicts)"
    end
  end

  describe "slugify/1" do
    test "converts titles to URL-safe slugs" do
      assert Knowledge.slugify("Hello World") == "hello-world"
      assert Knowledge.slugify("Ecto.Multi Pattern") == "ectomulti-pattern"
      assert Knowledge.slugify("What's New? (v2.0)") == "whats-new-v20"
      assert Knowledge.slugify("  leading  trailing  ") == "leading-trailing"
      assert Knowledge.slugify("multiple---dashes") == "multiple-dashes"
      assert Knowledge.slugify("UPPERCASE Title") == "uppercase-title"
      assert Knowledge.slugify("special!@#$chars") == "specialchars"
    end
  end
end
