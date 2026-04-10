defmodule Loopctl.Knowledge.ArticleLinkTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.ArticleLink

  describe "changeset/2" do
    test "valid changeset with all required fields and metadata defaults to %{}" do
      source_id = Ecto.UUID.generate()
      target_id = Ecto.UUID.generate()

      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: source_id,
          target_article_id: target_id,
          relationship_type: :relates_to
        })

      assert changeset.valid?
      assert get_field(changeset, :metadata) == %{}
      assert get_field(changeset, :relationship_type) == :relates_to
    end

    test "valid changeset with explicit metadata" do
      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: Ecto.UUID.generate(),
          target_article_id: Ecto.UUID.generate(),
          relationship_type: :derived_from,
          metadata: %{"reason" => "extracted from session"}
        })

      assert changeset.valid?
      assert get_field(changeset, :metadata) == %{"reason" => "extracted from session"}
    end

    test "rejects self-link (source == target)" do
      same_id = Ecto.UUID.generate()

      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: same_id,
          target_article_id: same_id,
          relationship_type: :relates_to
        })

      refute changeset.valid?
      assert "cannot link an article to itself" in errors_on(changeset)[:target_article_id]
    end

    test "rejects missing required fields" do
      changeset = ArticleLink.changeset(%ArticleLink{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:source_article_id]
      assert errors[:target_article_id]
      assert errors[:relationship_type]
    end

    test "rejects missing source_article_id" do
      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          target_article_id: Ecto.UUID.generate(),
          relationship_type: :relates_to
        })

      refute changeset.valid?
      assert errors_on(changeset)[:source_article_id]
    end

    test "rejects missing target_article_id" do
      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: Ecto.UUID.generate(),
          relationship_type: :relates_to
        })

      refute changeset.valid?
      assert errors_on(changeset)[:target_article_id]
    end

    test "rejects missing relationship_type" do
      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: Ecto.UUID.generate(),
          target_article_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:relationship_type]
    end

    test "validates all relationship_type enum values" do
      for rel_type <- [:relates_to, :derived_from, :contradicts, :supersedes] do
        changeset =
          ArticleLink.changeset(%ArticleLink{}, %{
            source_article_id: Ecto.UUID.generate(),
            target_article_id: Ecto.UUID.generate(),
            relationship_type: rel_type
          })

        assert changeset.valid?, "Expected #{rel_type} to be a valid relationship_type"
      end
    end

    test "rejects invalid relationship_type" do
      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: Ecto.UUID.generate(),
          target_article_id: Ecto.UUID.generate(),
          relationship_type: :invalid_type
        })

      refute changeset.valid?
      assert errors_on(changeset)[:relationship_type]
    end

    test "tenant_id is never in cast fields" do
      changeset =
        ArticleLink.changeset(%ArticleLink{}, %{
          source_article_id: Ecto.UUID.generate(),
          target_article_id: Ecto.UUID.generate(),
          relationship_type: :relates_to,
          tenant_id: Ecto.UUID.generate()
        })

      assert is_nil(get_change(changeset, :tenant_id))
    end
  end

  describe "schema fields" do
    test "has :inserted_at but NOT :updated_at" do
      fields = ArticleLink.__schema__(:fields)
      assert :inserted_at in fields
      refute :updated_at in fields
    end
  end

  describe "integration: insert and constraints" do
    test "inserts article link with valid data" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id})
      target = fixture(:article, %{tenant_id: tenant.id})

      changeset =
        %ArticleLink{tenant_id: tenant.id}
        |> ArticleLink.changeset(%{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })

      assert {:ok, link} = Loopctl.AdminRepo.insert(changeset)
      assert link.id
      assert link.tenant_id == tenant.id
      assert link.source_article_id == source.id
      assert link.target_article_id == target.id
      assert link.relationship_type == :relates_to
      assert link.metadata == %{}
      assert link.inserted_at
    end

    test "rejects duplicate link (same source, target, type)" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id})
      target = fixture(:article, %{tenant_id: tenant.id})

      attrs = %{
        source_article_id: source.id,
        target_article_id: target.id,
        relationship_type: :relates_to
      }

      changeset1 = %ArticleLink{tenant_id: tenant.id} |> ArticleLink.changeset(attrs)
      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset1)

      changeset2 = %ArticleLink{tenant_id: tenant.id} |> ArticleLink.changeset(attrs)
      assert {:error, changeset} = Loopctl.AdminRepo.insert(changeset2)

      assert "link already exists between these articles with this relationship type" in errors_on(
               changeset
             )[:tenant_id]
    end

    test "allows different relationship_type between same article pair" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id})
      target = fixture(:article, %{tenant_id: tenant.id})

      changeset1 =
        %ArticleLink{tenant_id: tenant.id}
        |> ArticleLink.changeset(%{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })

      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset1)

      changeset2 =
        %ArticleLink{tenant_id: tenant.id}
        |> ArticleLink.changeset(%{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :contradicts
        })

      assert {:ok, _} = Loopctl.AdminRepo.insert(changeset2)
    end

    test "FK constraint on source_article_id rejects invalid reference" do
      tenant = fixture(:tenant)
      target = fixture(:article, %{tenant_id: tenant.id})

      changeset =
        %ArticleLink{tenant_id: tenant.id}
        |> ArticleLink.changeset(%{
          source_article_id: Ecto.UUID.generate(),
          target_article_id: target.id,
          relationship_type: :relates_to
        })

      assert {:error, changeset} = Loopctl.AdminRepo.insert(changeset)
      assert errors_on(changeset)[:source_article_id]
    end

    test "FK constraint on target_article_id rejects invalid reference" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id})

      changeset =
        %ArticleLink{tenant_id: tenant.id}
        |> ArticleLink.changeset(%{
          source_article_id: source.id,
          target_article_id: Ecto.UUID.generate(),
          relationship_type: :derived_from
        })

      assert {:error, changeset} = Loopctl.AdminRepo.insert(changeset)
      assert errors_on(changeset)[:target_article_id]
    end
  end

  describe "integration: tenant isolation" do
    test "tenant A cannot see tenant B article links" do
      import Ecto.Query

      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      link_a = fixture(:article_link, %{tenant_id: tenant_a.id})
      link_b = fixture(:article_link, %{tenant_id: tenant_b.id})

      # Query scoped to tenant_a should only return tenant_a's link
      links_a =
        ArticleLink
        |> where([l], l.tenant_id == ^tenant_a.id)
        |> Loopctl.AdminRepo.all()

      assert length(links_a) == 1
      assert hd(links_a).id == link_a.id

      # Query scoped to tenant_b should only return tenant_b's link
      links_b =
        ArticleLink
        |> where([l], l.tenant_id == ^tenant_b.id)
        |> Loopctl.AdminRepo.all()

      assert length(links_b) == 1
      assert hd(links_b).id == link_b.id
    end
  end

  describe "fixture helpers" do
    test "build(:article_link) returns valid data map" do
      data = build(:article_link)
      assert data.relationship_type == :relates_to
      assert data.metadata == %{}
    end

    test "fixture(:article_link) creates link in database" do
      link = fixture(:article_link)
      assert link.id
      assert link.tenant_id
      assert link.source_article_id
      assert link.target_article_id
      assert link.relationship_type == :relates_to
    end

    test "fixture(:article_link) accepts overrides" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id})
      target = fixture(:article, %{tenant_id: tenant.id})

      link =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :supersedes
        })

      assert link.tenant_id == tenant.id
      assert link.source_article_id == source.id
      assert link.target_article_id == target.id
      assert link.relationship_type == :supersedes
    end
  end
end
