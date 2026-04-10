defmodule Loopctl.Knowledge.PipelineStatusTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  # --- TC-21.6.3: Pipeline status returns correct metrics ---

  describe "pipeline_status/1" do
    test "returns all expected fields with defaults for empty tenant" do
      tenant = fixture(:tenant)

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)

      assert result.pending_extractions == 0
      assert result.recent_drafts == []
      assert result.publish_rate == 0.0
      assert result.extraction_errors.count == 0
      assert result.extraction_errors.recent == []
      assert result.auto_extract_enabled == true
    end

    test "recent_drafts returns 20 most recent draft articles with source_type review_finding" do
      tenant = fixture(:tenant)

      # Create 25 draft articles with source_type "review_finding"
      for i <- 1..25 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Draft #{i}",
          status: :draft,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      # Create a published article (should not appear in recent_drafts)
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published one",
        status: :published,
        source_type: "review_finding",
        source_id: Ecto.UUID.generate()
      })

      # Create a draft without review_finding source (should not appear)
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Manual draft",
        status: :draft,
        source_type: "manual"
      })

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)

      assert length(result.recent_drafts) == 20
      assert Enum.all?(result.recent_drafts, &Map.has_key?(&1, :id))
      assert Enum.all?(result.recent_drafts, &Map.has_key?(&1, :title))
      assert Enum.all?(result.recent_drafts, &Map.has_key?(&1, :source_id))
      assert Enum.all?(result.recent_drafts, &Map.has_key?(&1, :inserted_at))

      # Verify ordering (most recent first)
      timestamps = Enum.map(result.recent_drafts, & &1.inserted_at)

      assert timestamps ==
               Enum.sort(timestamps, {:desc, DateTime})
    end

    test "publish_rate calculates ratio correctly" do
      tenant = fixture(:tenant)

      # 3 published + 2 draft = rate of 3/5 = 0.6
      for _ <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      for _ <- 1..2 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :draft,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)
      assert result.publish_rate == 0.6
    end

    test "publish_rate returns 0.0 when no review_finding articles exist" do
      tenant = fixture(:tenant)

      # Create an article with different source_type
      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        source_type: "manual"
      })

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)
      assert result.publish_rate == 0.0
    end

    test "publish_rate excludes archived and superseded articles" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        source_type: "review_finding",
        source_id: Ecto.UUID.generate()
      })

      # Archived articles should not count
      fixture(:article, %{
        tenant_id: tenant.id,
        status: :archived,
        source_type: "review_finding",
        source_id: Ecto.UUID.generate()
      })

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)
      # Only 1 published, 0 draft -> 1.0
      assert result.publish_rate == 1.0
    end

    test "auto_extract_enabled reflects tenant settings" do
      tenant = fixture(:tenant, %{settings: %{"knowledge_auto_extract" => false}})

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)
      assert result.auto_extract_enabled == false
    end

    # --- TC-21.6.7: Default auto_extract is true for new tenants ---

    test "auto_extract_enabled defaults to true for new tenants" do
      tenant = fixture(:tenant)

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)
      assert result.auto_extract_enabled == true
    end

    test "auto_extract_enabled is true when setting key is missing" do
      tenant = fixture(:tenant, %{settings: %{"other_key" => "value"}})

      assert {:ok, result} = Knowledge.pipeline_status(tenant.id)
      assert result.auto_extract_enabled == true
    end
  end

  # --- TC-21.6.5: Tenant isolation ---

  describe "tenant isolation" do
    test "pipeline metrics only reflect own tenant data" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      # Create articles for tenant A
      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant_a.id,
          title: "Tenant A Draft #{i}",
          status: :draft,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      fixture(:article, %{
        tenant_id: tenant_a.id,
        status: :published,
        source_type: "review_finding",
        source_id: Ecto.UUID.generate()
      })

      # Create articles for tenant B
      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant_b.id,
          title: "Tenant B Draft #{i}",
          status: :draft,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      # Check tenant A sees only its own data
      assert {:ok, result_a} = Knowledge.pipeline_status(tenant_a.id)
      assert length(result_a.recent_drafts) == 3
      # 1 published / (1 published + 3 draft) = 0.25
      assert result_a.publish_rate == 0.25

      # Check tenant B sees only its own data
      assert {:ok, result_b} = Knowledge.pipeline_status(tenant_b.id)
      assert length(result_b.recent_drafts) == 5
      assert result_b.publish_rate == 0.0
    end
  end
end
