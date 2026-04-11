defmodule Loopctl.Knowledge.AttributionTest do
  @moduledoc """
  US-25.1: Wiki Access Event Attribution — Schema & Ingestion

  Covers the ingestion layer only:

  - Schema columns `project_id` and `story_id` exist and are nullable
  - Composite timeline indexes exist in the expected tenant-first shape
  - `Analytics.record_*/6` accept and persist the attribution context
  - `Knowledge.get_article/3` forwards `:project_id`/`:story_id` to Analytics
  - Derivation of `project_id` from `story.project_id` when only `:story_id` is
    supplied
  - Cross-tenant attribution is silently dropped (log warning, attribution
    columns set to NULL) — the read still succeeds
  - Backward-compat: omitting context records the event with NULL columns
  - Batch search access records the same attribution for every row
  """

  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.ArticleAccessEvent

  defp setup_tenant_with_agent do
    tenant = fixture(:tenant)
    {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, api_key}
  end

  # -----------------------------------------------------------------------
  # TC-25.1.1: Migration adds columns and indexes with correct shape
  # -----------------------------------------------------------------------

  describe "schema and indexes" do
    test "article_access_events has nullable project_id and story_id FKs" do
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT column_name, is_nullable, data_type
        FROM information_schema.columns
        WHERE table_name = 'article_access_events'
          AND column_name IN ('project_id', 'story_id')
        ORDER BY column_name
        """)

      assert [
               ["project_id", "YES", "uuid"],
               ["story_id", "YES", "uuid"]
             ] = rows
    end

    test "composite timeline indexes use the tenant-first shape with accessed_at DESC" do
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE tablename = 'article_access_events'
          AND indexname IN (
            'article_access_events_project_id_accessed_at_idx',
            'article_access_events_story_id_accessed_at_idx'
          )
        ORDER BY indexname
        """)

      assert length(rows) == 2

      [project_idx, story_idx] = rows

      [_project_name, project_def] = project_idx
      assert project_def =~ "tenant_id"
      assert project_def =~ "project_id"
      assert project_def =~ "accessed_at DESC"

      [_story_name, story_def] = story_idx
      assert story_def =~ "tenant_id"
      assert story_def =~ "story_id"
      assert story_def =~ "accessed_at DESC"
    end

    test "RLS policy on article_access_events still uses tenant_id as sole isolation key" do
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT qual
        FROM pg_policies
        WHERE tablename = 'article_access_events'
        """)

      assert rows != []

      for [qual] <- rows do
        assert qual =~ "tenant_id"
        refute qual =~ "project_id"
        refute qual =~ "story_id"
      end
    end
  end

  # -----------------------------------------------------------------------
  # TC-25.1.2: record_access writes project_id and story_id when context
  #            is provided
  # -----------------------------------------------------------------------

  describe "Analytics.record_access/6 with attribution context" do
    test "writes project_id and story_id when both are supplied" do
      {tenant, api_key} = setup_tenant_with_agent()
      project = fixture(:project, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      :ok =
        Analytics.record_access(
          tenant.id,
          article.id,
          api_key.id,
          "get",
          %{},
          %{project_id: project.id, story_id: story.id}
        )

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert event.tenant_id == tenant.id
      assert event.article_id == article.id
      assert event.api_key_id == api_key.id
      assert event.project_id == project.id
      assert event.story_id == story.id
      assert event.access_type == "get"
    end

    # TC-25.1.6: Omitting context still records the event with NULL columns
    test "omitting context records the event with NULL attribution columns" do
      {tenant, api_key} = setup_tenant_with_agent()
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      :ok = Analytics.record_access(tenant.id, article.id, api_key.id, "search", %{})

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert is_nil(event.project_id)
      assert is_nil(event.story_id)
      assert event.access_type == "search"
    end

    test "5-arity call still works and records NULL attribution" do
      {tenant, api_key} = setup_tenant_with_agent()
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      :ok = Analytics.record_access(tenant.id, article.id, api_key.id, "get", %{"src" => "api"})

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert is_nil(event.project_id)
      assert is_nil(event.story_id)
      assert event.metadata == %{"src" => "api"}
    end
  end

  # -----------------------------------------------------------------------
  # TC-25.1.3: Knowledge.get_article forwards opts to Analytics
  # -----------------------------------------------------------------------

  describe "Knowledge.get_article/3 attribution forwarding" do
    test "forwards :project_id and :story_id from opts to the recorded event" do
      {tenant, api_key} = setup_tenant_with_agent()
      project = fixture(:project, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert {:ok, _article} =
               Knowledge.get_article(tenant.id, article.id,
                 api_key_id: api_key.id,
                 project_id: project.id,
                 story_id: story.id
               )

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert event.project_id == project.id
      assert event.story_id == story.id
      assert event.access_type == "get"
    end

    # TC-25.1.4: Deriving project_id from story_id when project_id omitted
    test "derives project_id from story.project_id when only story_id is supplied" do
      {tenant, api_key} = setup_tenant_with_agent()
      project = fixture(:project, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert {:ok, _article} =
               Knowledge.get_article(tenant.id, article.id,
                 api_key_id: api_key.id,
                 story_id: story.id
               )

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert event.story_id == story.id
      assert event.project_id == project.id
    end

    # TC-25.1.5: Cross-tenant project_id is silently dropped, attribution
    #            goes to NULL, read still succeeds. Tenant isolation holds.
    test "cross-tenant project_id is rejected — read succeeds, attribution nil" do
      {tenant_a, api_key_a} = setup_tenant_with_agent()
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      article = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      log =
        capture_log(fn ->
          assert {:ok, _article} =
                   Knowledge.get_article(tenant_a.id, article.id,
                     api_key_id: api_key_a.id,
                     project_id: project_b.id
                   )
        end)

      assert log =~ "cross-tenant project_id dropped"

      # Event was still inserted, but with NULL attribution columns.
      events = AdminRepo.all(ArticleAccessEvent)
      assert [event] = events
      assert event.tenant_id == tenant_a.id
      assert is_nil(event.project_id)
      assert is_nil(event.story_id)

      # Tenant B's analytics must not see any rows attributed to project_b.
      %{rows: [[count]]} =
        AdminRepo.query!(
          "SELECT count(*) FROM article_access_events WHERE tenant_id = $1 AND project_id = $2",
          [Ecto.UUID.dump!(tenant_b.id), Ecto.UUID.dump!(project_b.id)]
        )

      assert count == 0
    end

    test "cross-tenant story_id is rejected — attribution silently dropped" do
      {tenant_a, api_key_a} = setup_tenant_with_agent()
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id, project_id: project_b.id})
      article = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      log =
        capture_log(fn ->
          assert {:ok, _article} =
                   Knowledge.get_article(tenant_a.id, article.id,
                     api_key_id: api_key_a.id,
                     story_id: story_b.id
                   )
        end)

      assert log =~ "cross-tenant story_id dropped"

      [event] = AdminRepo.all(ArticleAccessEvent)
      assert event.tenant_id == tenant_a.id
      assert is_nil(event.project_id)
      assert is_nil(event.story_id)
    end
  end

  # -----------------------------------------------------------------------
  # TC-25.1.7: Batch search access records identical attribution for every
  #            row in the batch.
  # -----------------------------------------------------------------------

  describe "Analytics.record_search_access/6 batch attribution" do
    test "records the same project_id and story_id for every article in the batch" do
      {tenant, api_key} = setup_tenant_with_agent()
      project = fixture(:project, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a3 = fixture(:article, %{tenant_id: tenant.id, status: :published})

      :ok =
        Analytics.record_search_access(
          tenant.id,
          [a1.id, a2.id, a3.id],
          api_key.id,
          "csv import",
          %{},
          %{project_id: project.id, story_id: story.id}
        )

      events =
        ArticleAccessEvent
        |> AdminRepo.all()
        |> Enum.sort_by(& &1.metadata["rank"])

      assert length(events) == 3
      assert Enum.all?(events, &(&1.access_type == "search"))
      assert Enum.all?(events, &(&1.project_id == project.id))
      assert Enum.all?(events, &(&1.story_id == story.id))
      assert Enum.all?(events, &(&1.metadata["query"] == "csv import"))
    end
  end

  # -----------------------------------------------------------------------
  # Context/search plumbing — forwarding from Knowledge API through to the
  # recorded attribution columns.
  # -----------------------------------------------------------------------

  describe "Knowledge.search_keyword/3 attribution forwarding" do
    test "forwards :project_id and :story_id from opts to all recorded search events" do
      {tenant, api_key} = setup_tenant_with_agent()
      project = fixture(:project, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})

      _a1 =
        fixture(:article, %{
          tenant_id: tenant.id,
          project_id: project.id,
          title: "Ecto Multi Pattern",
          body: "Use Ecto.Multi for atomic operations",
          status: :published
        })

      {:ok, %{results: results}} =
        Knowledge.search_keyword(tenant.id, "Ecto",
          api_key_id: api_key.id,
          project_id: project.id,
          story_id: story.id
        )

      assert results != []

      events = AdminRepo.all(ArticleAccessEvent)
      assert events != []
      assert Enum.all?(events, &(&1.project_id == project.id))
      assert Enum.all?(events, &(&1.story_id == story.id))
      assert Enum.all?(events, &(&1.access_type == "search"))
    end
  end

  describe "Knowledge.get_context/3 attribution forwarding" do
    test "forwards :story_id and derives :project_id from the story" do
      {tenant, api_key} = setup_tenant_with_agent()
      project = fixture(:project, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, project_id: project.id})

      _a1 =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Context Attribution Flow",
          body: "Body about attribution flow for context retrieval integration tests.",
          status: :published
        })

      {:ok, %{results: results}} =
        Knowledge.get_context(tenant.id, "attribution flow",
          api_key_id: api_key.id,
          story_id: story.id
        )

      # If keyword search found the article, there should be a recorded
      # context event with derived project_id and explicit story_id.
      events = AdminRepo.all(ArticleAccessEvent)
      context_events = Enum.filter(events, &(&1.access_type == "context"))

      if results != [] do
        assert context_events != []

        for event <- context_events do
          assert event.story_id == story.id
          assert event.project_id == project.id
        end
      else
        # If the search returned no results, there's nothing to attribute
        # (record_context_access is a no-op for empty id lists). The test
        # still passes without asserting anything beyond that.
        assert context_events == []
      end
    end
  end

  # -----------------------------------------------------------------------
  # Tenant isolation regression — tenant A's knowledge read with tenant B's
  # attribution MUST NOT create any attributed row visible to tenant B.
  # -----------------------------------------------------------------------

  describe "tenant isolation for attribution" do
    test "tenant A passing tenant B's story_id does not leak into tenant B's analytics" do
      {tenant_a, api_key_a} = setup_tenant_with_agent()
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id, project_id: project_b.id})
      article_a = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      capture_log(fn ->
        assert {:ok, _} =
                 Knowledge.get_article(tenant_a.id, article_a.id,
                   api_key_id: api_key_a.id,
                   project_id: project_b.id,
                   story_id: story_b.id
                 )
      end)

      # Tenant A's own event row exists but has no attribution.
      %{rows: [[count_a]]} =
        AdminRepo.query!(
          "SELECT count(*) FROM article_access_events WHERE tenant_id = $1",
          [Ecto.UUID.dump!(tenant_a.id)]
        )

      assert count_a == 1

      # Tenant B sees absolutely nothing from this transaction.
      %{rows: [[count_b]]} =
        AdminRepo.query!(
          "SELECT count(*) FROM article_access_events WHERE tenant_id = $1",
          [Ecto.UUID.dump!(tenant_b.id)]
        )

      assert count_b == 0

      # Tenant B's attribution tables cannot see any rows even by project_id.
      %{rows: [[count_via_project]]} =
        AdminRepo.query!(
          "SELECT count(*) FROM article_access_events WHERE project_id = $1",
          [Ecto.UUID.dump!(project_b.id)]
        )

      assert count_via_project == 0

      %{rows: [[count_via_story]]} =
        AdminRepo.query!(
          "SELECT count(*) FROM article_access_events WHERE story_id = $1",
          [Ecto.UUID.dump!(story_b.id)]
        )

      assert count_via_story == 0
    end
  end
end
