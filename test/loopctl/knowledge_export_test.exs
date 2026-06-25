defmodule Loopctl.KnowledgeExportTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.StreamingExport.ObsidianFormat
  alias Loopctl.StreamingExportHelper

  # US-27.16: the Obsidian export is now a bounded-memory streamed `.tar.gz` built
  # by Loopctl.Knowledge.StreamingExport. These context-level tests drive the
  # streaming core via the in-memory collector helper and unpack the tar.gz.
  defp export_obsidian(tenant_id, opts \\ []) do
    {:ok, targz} = StreamingExportHelper.to_targz_binary(tenant_id, ObsidianFormat, opts)
    {:ok, files} = StreamingExportHelper.extract(targz)
    files
  end

  describe "streamed Obsidian export" do
    test "returns archive with published articles organized by category" do
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

      file_map = export_obsidian(tenant.id)

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

      filenames = tenant.id |> export_obsidian() |> Map.keys()

      assert "_index.md" in filenames
      assert "pattern/published.md" in filenames
      refute "pattern/draft.md" in filenames
      refute "convention/archived.md" in filenames
    end

    test "scopes by project_id when provided (incl. the project_id IS NULL disjunction)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})

      # Tenant-wide (nil project) -- included
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

      filenames = tenant.id |> export_obsidian(project_id: project.id) |> Map.keys()

      assert "pattern/global.md" in filenames
      assert "convention/in-project.md" in filenames
      refute "finding/other-project.md" in filenames
    end

    test "returns archive with only _index.md when no published articles" do
      tenant = fixture(:tenant)

      file_map = export_obsidian(tenant.id)

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

      file_map = export_obsidian(tenant_a.id)
      filenames = Map.keys(file_map)

      assert "pattern/a-article.md" in filenames
      refute "pattern/b-article.md" in filenames

      # No tenant B content in any entry (BYPASSRLS scope proof).
      all = file_map |> Map.values() |> Enum.join("\n")
      refute all =~ "B Article"
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

      content = export_obsidian(tenant.id)["finding/full-article.md"]

      assert content =~ ~s(title: "Full Article")
      assert content =~ "category: finding"
      assert content =~ "tags:\n  - tag1\n  - tag2"
      assert content =~ "status: published"
      assert content =~ "source_type: manual"
      assert content =~ "created_at:"
      assert content =~ "updated_at:"
      assert content =~ "The full body content."
    end

    test "related articles rendered as wikilinks with link types (both directions)" do
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

      file_map = export_obsidian(tenant.id)

      source_md = file_map["pattern/source.md"]
      assert source_md =~ "## Related Articles"
      assert source_md =~ "[[Target]] (contradicts)"

      target_md = file_map["decision/target.md"]
      assert target_md =~ "## Related Articles"
      assert target_md =~ "[[Source]] (contradicts)"
    end

    test "_index.md is a cheap per-category aggregate (counts, not titles)" do
      tenant = fixture(:tenant)

      for i <- 1..2 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Pattern #{i}",
          body: "b",
          category: :pattern,
          status: :published
        })
      end

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "One Decision",
        body: "b",
        category: :decision,
        status: :published
      })

      index = export_obsidian(tenant.id)["_index.md"]

      assert index =~ "# Knowledge Base Index"
      assert index =~ "## Pattern\n\n2 article(s)"
      assert index =~ "## Decision\n\n1 article(s)"
      # Titles are NOT loaded for the index (bounded memory).
      refute index =~ "[[Pattern 1]]"
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

    test "returns 'untitled' for all-special-character titles" do
      assert Knowledge.slugify("!!!") == "untitled"
      assert Knowledge.slugify("@#$%") == "untitled"
      assert Knowledge.slugify("...") == "untitled"
    end
  end
end
