defmodule Loopctl.Knowledge.OKFTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.OKF

  @fixtures_root Path.join([File.cwd!(), "test", "support", "okf_fixtures"])

  defp published(tenant_id, attrs) do
    fixture(
      :article,
      Map.merge(%{tenant_id: tenant_id, status: :published}, Enum.into(attrs, %{}))
    )
  end

  # Walks a vendored Google sample bundle into a bundle-relative files map.
  defp load_fixture_bundle(name) do
    root = Path.join(@fixtures_root, name)

    root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Map.new(fn abs ->
      {Path.relative_to(abs, root), File.read!(abs)}
    end)
  end

  describe "parse_frontmatter/1 + encode_frontmatter/1" do
    test "round-trips a typical frontmatter map" do
      fm = %{
        "type" => "pattern",
        "title" => "Use Ecto.Multi",
        "description" => "Atomic multi-step ops: a, b, c.",
        "tags" => ["ecto", "transactions"],
        "timestamp" => "2026-05-28T22:43:59Z"
      }

      doc = "---\n#{OKF.encode_frontmatter(fm)}---\n\nbody text\n"

      assert {:ok, %{frontmatter: parsed, body: body}} = OKF.parse_frontmatter(doc)
      assert parsed["type"] == "pattern"
      assert parsed["title"] == "Use Ecto.Multi"
      assert parsed["description"] == "Atomic multi-step ops: a, b, c."
      assert parsed["tags"] == ["ecto", "transactions"]
      assert String.trim(body) == "body text"
    end

    test "reports missing frontmatter" do
      assert {:error, :no_frontmatter} = OKF.parse_frontmatter("no frontmatter here")
    end

    test "tolerates CRLF line endings" do
      doc = "---\r\ntype: reference\r\ntitle: X\r\n---\r\n\r\nbody\r\n"

      assert {:ok, %{frontmatter: %{"type" => "reference", "title" => "X"}}} =
               OKF.parse_frontmatter(doc)
    end
  end

  describe "build_bundle/2 (export)" do
    test "produces a conformant bundle with reserved files and concept docs" do
      tenant = fixture(:tenant)

      published(tenant.id, %{title: "Alpha Pattern", category: :pattern, tags: ["a"]})
      published(tenant.id, %{title: "Beta Reference", category: :reference, tags: ["b", "hub"]})

      assert {:ok, %{files: files, meta: meta}} = OKF.build_bundle(tenant.id)

      assert meta.okf_version == "0.1"
      assert meta.article_count == 2

      # Reserved files present
      assert Map.has_key?(files, "index.md")
      assert Map.has_key?(files, "log.md")
      assert Map.has_key?(files, "pattern/index.md")
      assert Map.has_key?(files, "reference/index.md")

      # Root index declares okf_version
      assert files["index.md"] =~ ~s(okf_version: "0.1")

      # Concept files at <category>/<slug>.md
      assert Map.has_key?(files, "pattern/alpha-pattern.md")
      concept = files["pattern/alpha-pattern.md"]
      assert {:ok, %{frontmatter: fm}} = OKF.parse_frontmatter(concept)
      assert fm["type"] == "pattern"
      assert fm["title"] == "Alpha Pattern"
      assert fm["tags"] == ["a"]
      assert is_binary(fm["loopctl_id"])
      assert fm["loopctl_status"] == "published"

      # The whole bundle is OKF-conformant
      assert %{conformant: true, errors: []} = OKF.validate_files(files)
    end

    test "only exports the tenant's own published articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      published(tenant_a.id, %{title: "A Visible", category: :pattern})
      published(tenant_b.id, %{title: "B Hidden", category: :pattern})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "A Draft",
        category: :pattern,
        status: :draft
      })

      assert {:ok, %{files: files, meta: meta}} = OKF.build_bundle(tenant_a.id)
      assert meta.article_count == 1
      assert Map.has_key?(files, "pattern/a-visible.md")
      refute Map.has_key?(files, "pattern/b-hidden.md")
      refute Map.has_key?(files, "pattern/a-draft.md")
    end

    test "encodes the relates_to graph as a Related section" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Source Note", category: :finding})
      b = published(tenant.id, %{title: "Target Note", category: :finding})

      {:ok, _} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: a.id,
          target_article_id: b.id,
          relationship_type: :relates_to
        })

      assert {:ok, %{files: files}} = OKF.build_bundle(tenant.id)
      concept = files["finding/source-note.md"]
      assert concept =~ "# Related"
      assert concept =~ "(/finding/target-note.md)"
      assert concept =~ "relates_to"
    end
  end

  describe "to_zip/1 + import_zip/3 round-trip" do
    test "a zipped bundle imports back into articles" do
      source = fixture(:tenant)

      published(source.id, %{title: "Zip Me", category: :decision, body: "decided x", tags: ["t"]})

      {:ok, %{files: files}} = OKF.build_bundle(source.id)
      zip = OKF.to_zip(files)

      dest = fixture(:tenant)
      assert {:ok, report} = OKF.import_zip(dest.id, zip)
      assert report.created == 1
      assert report.errors == []

      %{data: [a]} = Knowledge.list_articles(dest.id, category: :decision)
      assert a.title == "Zip Me"
    end
  end

  describe "import_files/3 (round-trip fidelity for loopctl bundles)" do
    test "restores title, category, tags, status, body, and relates_to links" do
      source = fixture(:tenant)

      a =
        published(source.id, %{
          title: "Hub Article",
          category: :reference,
          tags: ["hub"],
          body: "hub body"
        })

      b = published(source.id, %{title: "Leaf Article", category: :finding, body: "leaf body"})

      {:ok, _} =
        Knowledge.create_link(source.id, %{
          source_article_id: a.id,
          target_article_id: b.id,
          relationship_type: :relates_to
        })

      {:ok, %{files: files}} = OKF.build_bundle(source.id)

      dest = fixture(:tenant)
      assert {:ok, report} = OKF.import_files(dest.id, files)
      assert report.created == 2
      assert report.errors == []

      %{data: refs} = Knowledge.list_articles(dest.id, category: :reference)
      hub = Enum.find(refs, &(&1.title == "Hub Article"))
      assert hub
      assert hub.tags == ["hub"]
      assert hub.status == :published

      # Body restored verbatim — the generated Related section is stripped.
      {:ok, full} = Knowledge.get_article(dest.id, hub.id)
      assert String.trim(full.body) == "hub body"
      refute full.body =~ "# Related"

      # Relationship reconstructed
      links = Knowledge.list_links_for_article(dest.id, hub.id)
      assert Enum.any?(links, fn l -> l.relationship_type == :relates_to end)
    end

    test "merge updates existing articles instead of duplicating them" do
      source = fixture(:tenant)
      published(source.id, %{title: "Idempotent", category: :pattern, body: "v1"})
      {:ok, %{files: files}} = OKF.build_bundle(source.id)

      dest = fixture(:tenant)
      {:ok, first} = OKF.import_files(dest.id, files)
      assert first.created == 1

      {:ok, second} = OKF.import_files(dest.id, files, merge: true)
      assert second.created == 0
      assert second.updated == 1

      %{meta: %{total_count: total}} = Knowledge.list_articles(dest.id, category: :pattern)
      assert total == 1
    end

    test "merge:false skips existing articles" do
      source = fixture(:tenant)
      published(source.id, %{title: "Keep Me", category: :pattern, body: "v1"})
      {:ok, %{files: files}} = OKF.build_bundle(source.id)

      dest = fixture(:tenant)
      {:ok, _} = OKF.import_files(dest.id, files)
      {:ok, again} = OKF.import_files(dest.id, files, merge: false)
      assert again.created == 0
      assert again.skipped >= 1
    end

    test "dry_run writes nothing" do
      source = fixture(:tenant)
      published(source.id, %{title: "Ghost", category: :pattern})
      {:ok, %{files: files}} = OKF.build_bundle(source.id)

      dest = fixture(:tenant)
      {:ok, report} = OKF.import_files(dest.id, files, dry_run: true)
      assert report.created == 1
      assert %{meta: %{total_count: 0}} = Knowledge.list_articles(dest.id, category: :pattern)
    end

    test "tenant isolation — import lands only in the target tenant" do
      source = fixture(:tenant)
      published(source.id, %{title: "Scoped", category: :pattern})
      {:ok, %{files: files}} = OKF.build_bundle(source.id)

      dest = fixture(:tenant)
      other = fixture(:tenant)
      {:ok, _} = OKF.import_files(dest.id, files)

      assert %{meta: %{total_count: 1}} = Knowledge.list_articles(dest.id, category: :pattern)
      assert %{meta: %{total_count: 0}} = Knowledge.list_articles(other.id, category: :pattern)
    end
  end

  describe "Google sample bundles (vendored fixtures)" do
    for bundle <- ["crypto_bitcoin", "ga4", "stackoverflow"] do
      test "#{bundle}: validates as OKF-conformant" do
        files = load_fixture_bundle(unquote(bundle))
        result = OKF.validate_files(files)

        assert result.conformant,
               "expected #{unquote(bundle)} to be conformant, errors: #{inspect(result.errors)}"

        assert result.concept_count > 0
      end

      test "#{bundle}: imports without errors, preserving unknown frontmatter" do
        files = load_fixture_bundle(unquote(bundle))
        tenant = fixture(:tenant)

        assert {:ok, report} = OKF.import_files(tenant.id, files)
        assert report.errors == []
        assert report.created + report.updated == report.conformance.concept_count

        # Foreign types fall back to the reference category, original type preserved.
        %{data: refs} = Knowledge.list_articles(tenant.id, category: :reference, limit: 100)
        assert refs != []
        sample = hd(refs)
        {:ok, full} = Knowledge.get_article(tenant.id, sample.id)
        assert is_binary(full.metadata["okf"]["type"])
      end
    end

    test "re-exporting an imported Google bundle stays conformant" do
      files = load_fixture_bundle("crypto_bitcoin")
      tenant = fixture(:tenant)
      {:ok, _} = OKF.import_files(tenant.id, files)

      # Imported as drafts (foreign bundle) — publish so they re-export.
      %{data: arts} =
        Knowledge.list_articles(tenant.id, category: :reference, limit: 100, status: :draft)

      for a <- arts do
        {:ok, _} = Knowledge.publish_article(tenant.id, a.id)
      end

      assert {:ok, %{files: out}} = OKF.build_bundle(tenant.id)
      assert %{conformant: true, errors: []} = OKF.validate_files(out)
    end
  end

  describe "validate_files/1" do
    test "flags a concept missing a type" do
      files = %{"x.md" => "---\ntitle: No Type\n---\n\nbody\n"}
      result = OKF.validate_files(files)
      refute result.conformant
      assert [%{path: "x.md"}] = result.errors
    end

    test "flags a concept with no frontmatter" do
      files = %{"x.md" => "just a body, no frontmatter"}
      result = OKF.validate_files(files)
      refute result.conformant
    end

    test "reserved index.md/log.md do not require frontmatter" do
      files = %{
        "index.md" => "# Bundle\n\n* [x](x.md)\n",
        "log.md" => "# Log\n\n## 2026-06-18\n* **Update**: x\n",
        "x.md" => "---\ntype: reference\ntitle: X\n---\n\nbody\n"
      }

      assert %{conformant: true, errors: []} = OKF.validate_files(files)
    end
  end
end
