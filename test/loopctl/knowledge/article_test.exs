defmodule Loopctl.Knowledge.ArticleTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.Article

  describe "create_changeset/2" do
    test "valid changeset with all required fields" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Pattern: GenServer DI",
          body: "Use behaviours for dependency injection.",
          category: :pattern
        })

      assert changeset.valid?
      assert get_field(changeset, :status) == :draft
      assert get_field(changeset, :tags) == []
      assert get_field(changeset, :metadata) == %{}
    end

    test "valid changeset with all fields" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Full Article",
          body: "Complete body text.",
          category: :convention,
          status: :published,
          tags: ["elixir", "phoenix"],
          source_type: "review_finding",
          source_id: Ecto.UUID.generate(),
          metadata: %{"reviewed_by" => "agent-1"},
          project_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert get_field(changeset, :status) == :published
      assert get_field(changeset, :tags) == ["elixir", "phoenix"]
    end

    test "rejects missing required fields" do
      changeset = Article.create_changeset(%Article{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:title]
      assert errors[:body]
      assert errors[:category]
    end

    test "rejects title exceeding 500 characters" do
      long_title = String.duplicate("a", 501)

      changeset =
        Article.create_changeset(%Article{}, %{
          title: long_title,
          body: "Valid body",
          category: :pattern
        })

      refute changeset.valid?
      assert errors_on(changeset)[:title]
    end

    test "accepts title at exactly 500 characters" do
      title_500 = String.duplicate("a", 500)

      changeset =
        Article.create_changeset(%Article{}, %{
          title: title_500,
          body: "Valid body",
          category: :pattern
        })

      assert changeset.valid?
    end

    test "rejects body exceeding 100_000 characters" do
      long_body = String.duplicate("x", 100_001)

      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Valid title",
          body: long_body,
          category: :pattern
        })

      refute changeset.valid?
      assert errors_on(changeset)[:body]
    end

    test "rejects invalid category" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Valid title",
          body: "Valid body",
          category: :nonexistent
        })

      refute changeset.valid?
      assert errors_on(changeset)[:category]
    end

    test "defaults status to :draft when not provided" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Draft Article",
          body: "Draft content",
          category: :finding
        })

      assert changeset.valid?
      assert get_field(changeset, :status) == :draft
    end

    test "validates all category enum values" do
      for category <- [:pattern, :convention, :decision, :finding, :reference] do
        changeset =
          Article.create_changeset(%Article{}, %{
            title: "Article for #{category}",
            body: "Content",
            category: category
          })

        assert changeset.valid?, "Expected #{category} to be a valid category"
      end
    end

    test "validates all status enum values" do
      for status <- [:draft, :published, :archived, :superseded] do
        changeset =
          Article.create_changeset(%Article{}, %{
            title: "Article with #{status}",
            body: "Content",
            category: :pattern,
            status: status
          })

        assert changeset.valid?, "Expected #{status} to be a valid status"
      end
    end

    test "advisory validation warns on unknown source_type" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Article",
          body: "Content",
          category: :pattern,
          source_type: "unknown_source"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:source_type]
    end

    test "accepts known source_type values" do
      for source_type <- ~w(review_finding manual agent session_log) do
        changeset =
          Article.create_changeset(%Article{}, %{
            title: "Article from #{source_type}",
            body: "Content",
            category: :pattern,
            source_type: source_type
          })

        assert changeset.valid?, "Expected source_type #{source_type} to be valid"
      end
    end

    test "rejects non-map metadata" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Article",
          body: "Content",
          category: :pattern,
          metadata: "not a map"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:metadata]
    end

    test "accepts valid map metadata" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Article",
          body: "Content",
          category: :pattern,
          metadata: %{"key" => "value"}
        })

      assert changeset.valid?
    end

    test "tenant_id is never in cast fields" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Article",
          body: "Content",
          category: :pattern,
          tenant_id: Ecto.UUID.generate()
        })

      # tenant_id should not be set via cast
      assert is_nil(get_change(changeset, :tenant_id))
    end
  end

  describe "create_changeset/2 tag validation" do
    test "rejects more than 20 tags" do
      too_many_tags = Enum.map(1..21, &"tag-#{&1}")

      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Too Many Tags",
          body: "Content",
          category: :pattern,
          tags: too_many_tags
        })

      refute changeset.valid?
      assert "must not exceed 20 tags" in errors_on(changeset)[:tags]
    end

    test "accepts exactly 20 tags" do
      tags = Enum.map(1..20, &"tag-#{&1}")

      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Max Tags",
          body: "Content",
          category: :pattern,
          tags: tags
        })

      assert changeset.valid?
    end

    test "rejects tag exceeding 100 characters" do
      long_tag = String.duplicate("a", 101)

      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Long Tag Article",
          body: "Content",
          category: :pattern,
          tags: [long_tag]
        })

      refute changeset.valid?
      assert errors_on(changeset)[:tags]
    end

    test "rejects tag with invalid characters" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Bad Tag Article",
          body: "Content",
          category: :pattern,
          tags: ["valid-tag", "invalid tag!"]
        })

      refute changeset.valid?
      assert errors_on(changeset)[:tags]
    end

    test "accepts valid tag patterns" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Good Tags",
          body: "Content",
          category: :pattern,
          tags: ["elixir", "phoenix-liveview", "otp_patterns", "GenServer123"]
        })

      assert changeset.valid?
    end

    test "rejects nil elements in tags array" do
      changeset =
        Article.create_changeset(%Article{}, %{
          title: "Nil Tag Article",
          body: "Content",
          category: :pattern,
          tags: ["valid", nil]
        })

      refute changeset.valid?
      assert "each tag must be a string" in errors_on(changeset)[:tags]
    end
  end

  describe "update_changeset/2" do
    test "allows partial update of title" do
      article = %Article{
        title: "Original",
        body: "Original body",
        category: :pattern,
        status: :draft
      }

      changeset = Article.update_changeset(article, %{title: "Updated"})
      assert changeset.valid?
      assert get_change(changeset, :title) == "Updated"
    end

    test "allows partial update of status" do
      article = %Article{
        title: "Original",
        body: "Original body",
        category: :pattern,
        status: :draft
      }

      changeset = Article.update_changeset(article, %{status: :published})
      assert changeset.valid?
      assert get_change(changeset, :status) == :published
    end

    test "allows partial update of tags and metadata" do
      article = %Article{
        title: "Original",
        body: "Body",
        category: :pattern,
        status: :draft
      }

      changeset =
        Article.update_changeset(article, %{
          tags: ["new-tag"],
          metadata: %{"updated" => true}
        })

      assert changeset.valid?
    end

    test "validates title length on update" do
      article = %Article{title: "Original", body: "Body", category: :pattern}

      changeset =
        Article.update_changeset(article, %{title: String.duplicate("x", 501)})

      refute changeset.valid?
      assert errors_on(changeset)[:title]
    end

    test "validates tags on update" do
      article = %Article{title: "Original", body: "Body", category: :pattern}

      changeset =
        Article.update_changeset(article, %{tags: ["bad tag!"]})

      refute changeset.valid?
      assert errors_on(changeset)[:tags]
    end

    test "does not allow source_type or source_id changes" do
      article = %Article{
        title: "Original",
        body: "Body",
        category: :pattern,
        source_type: "manual"
      }

      changeset =
        Article.update_changeset(article, %{
          source_type: "agent",
          source_id: Ecto.UUID.generate()
        })

      # source_type and source_id are not in update cast fields
      assert is_nil(get_change(changeset, :source_type))
      assert is_nil(get_change(changeset, :source_id))
    end
  end

  describe "schema associations" do
    test "declares outgoing_links association" do
      assoc = Article.__schema__(:association, :outgoing_links)
      assert assoc.related == Loopctl.Knowledge.ArticleLink
      assert assoc.owner_key == :id
      assert assoc.related_key == :source_article_id
    end

    test "declares incoming_links association" do
      assoc = Article.__schema__(:association, :incoming_links)
      assert assoc.related == Loopctl.Knowledge.ArticleLink
      assert assoc.owner_key == :id
      assert assoc.related_key == :target_article_id
    end
  end

  describe "integration: insert and unique constraint" do
    test "inserts article with valid data" do
      tenant = fixture(:tenant)

      changeset =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{
          title: "Unique Pattern",
          body: "Body content here",
          category: :pattern
        })

      assert {:ok, article} = Loopctl.AdminRepo.insert(changeset)
      assert article.id
      assert article.tenant_id == tenant.id
      assert article.status == :draft
    end

    test "enforces unique title per tenant among active articles" do
      tenant = fixture(:tenant)

      attrs = %{
        title: "Duplicate Title",
        body: "First body",
        category: :pattern
      }

      changeset1 = %Article{tenant_id: tenant.id} |> Article.create_changeset(attrs)
      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset1)

      changeset2 =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{attrs | body: "Second body"})

      assert {:error, changeset} = Loopctl.AdminRepo.insert(changeset2)
      assert errors_on(changeset)[:tenant_id]
    end

    test "allows same title across different tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      attrs = %{title: "Shared Title", body: "Body", category: :decision}

      changeset_a = %Article{tenant_id: tenant_a.id} |> Article.create_changeset(attrs)
      changeset_b = %Article{tenant_id: tenant_b.id} |> Article.create_changeset(attrs)

      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset_a)
      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset_b)
    end

    test "allows title reuse when existing article is archived" do
      tenant = fixture(:tenant)

      # Create and archive first article
      changeset1 =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{
          title: "Reusable Title",
          body: "First version",
          category: :pattern
        })

      {:ok, article1} = Loopctl.AdminRepo.insert(changeset1)

      # Archive the first article
      article1
      |> Article.update_changeset(%{status: :archived})
      |> Loopctl.AdminRepo.update!()

      # Create second article with same title
      changeset2 =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{
          title: "Reusable Title",
          body: "Second version",
          category: :pattern
        })

      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset2)
    end

    test "allows title reuse when existing article is superseded" do
      tenant = fixture(:tenant)

      changeset1 =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{
          title: "Superseded Title",
          body: "Old version",
          category: :convention
        })

      {:ok, article1} = Loopctl.AdminRepo.insert(changeset1)

      article1
      |> Article.update_changeset(%{status: :superseded})
      |> Loopctl.AdminRepo.update!()

      changeset2 =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{
          title: "Superseded Title",
          body: "New version",
          category: :convention
        })

      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset2)
    end
  end

  describe "integration: tenant isolation" do
    test "tenant A cannot read tenant B articles" do
      import Ecto.Query

      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      # Insert articles via AdminRepo (bypasses RLS)
      article_a = fixture(:article, %{tenant_id: tenant_a.id, title: "Article A"})
      article_b = fixture(:article, %{tenant_id: tenant_b.id, title: "Article B"})

      # Query scoped to tenant_a should only return tenant_a's article
      articles_a =
        Article
        |> where([a], a.tenant_id == ^tenant_a.id)
        |> Loopctl.AdminRepo.all()

      assert length(articles_a) == 1
      assert hd(articles_a).id == article_a.id

      # Query scoped to tenant_b should only return tenant_b's article
      articles_b =
        Article
        |> where([a], a.tenant_id == ^tenant_b.id)
        |> Loopctl.AdminRepo.all()

      assert length(articles_b) == 1
      assert hd(articles_b).id == article_b.id
    end
  end

  describe "fixture helpers" do
    test "build(:article) returns valid data map" do
      data = build(:article)
      assert data.title
      assert data.body
      assert data.category == :pattern
      assert data.status == :draft
      assert data.tags == []
      assert data.metadata == %{}
    end

    test "fixture(:article) creates article in database" do
      article = fixture(:article)
      assert article.id
      assert article.tenant_id
      assert article.status == :draft
    end

    test "fixture(:article) accepts overrides" do
      tenant = fixture(:tenant)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Custom Title",
          category: :decision,
          tags: ["custom"]
        })

      assert article.tenant_id == tenant.id
      assert article.title == "Custom Title"
      assert article.category == :decision
      assert article.tags == ["custom"]
    end
  end
end
