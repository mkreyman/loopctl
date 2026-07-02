defmodule Loopctl.WorkBreakdown.QueriesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Loopctl.PlanAssertions, only: [capture_repo_queries: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Queries
  alias Loopctl.WorkBreakdown.Story

  defp setup_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project}
  end

  # sort_key is computed from the story number (not castable). To create the
  # duplicate-sort_key condition that destabilizes pagination, force a constant
  # sort_key directly on the given story ids.
  defp force_sort_key(story_ids, value) do
    from(s in Story, where: s.id in ^story_ids)
    |> AdminRepo.update_all(set: [sort_key: value])
  end

  describe "list_ready_stories/2" do
    test "returns pending stories with no dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      assert story.id in ids
    end

    test "excludes stories with unverified dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      dep_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :pending,
          verified_status: :unverified
        })

      blocked_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked_story.id,
        depends_on_story_id: dep_story.id
      })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      # dep_story is ready (no deps), blocked_story is not
      assert dep_story.id in ids
      refute blocked_story.id in ids
    end

    test "includes stories whose dependencies are all verified" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      verified_dep =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          verified_status: :verified
        })

      ready_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: ready_story.id,
        depends_on_story_id: verified_dep.id
      })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      assert ready_story.id in ids
    end

    test "excludes non-pending stories" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :assigned
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)
      assert result.data == []
    end

    test "filters by epic_id" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      story_in_1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_1.id,
          number: "1.1",
          agent_status: :pending
        })

      _story_in_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_2.id,
          number: "2.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_ready_stories(tenant.id, epic_id: epic_1.id)

      ids = Enum.map(result.data, & &1.id)
      assert length(ids) == 1
      assert story_in_1.id in ids
    end

    test "respects epic-level dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      # Epic 2 depends on Epic 1
      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      # Epic 1 has an unverified story
      _story_1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_1.id,
          number: "1.1",
          agent_status: :reported_done,
          verified_status: :unverified
        })

      # Epic 2 has a pending story
      story_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_2.id,
          number: "2.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      # story_2 should NOT be ready because epic 1 has unverified stories
      refute story_2.id in ids
    end
  end

  describe "list_blocked_stories/2" do
    test "returns stories with blocking dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      blocked =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked.id,
        depends_on_story_id: blocker.id
      })

      {:ok, result} = Queries.list_blocked_stories(tenant.id, project_id: project.id)

      assert length(result.data) == 1
      item = hd(result.data)
      assert item.story.id == blocked.id
      assert length(item.blocking_dependencies) == 1
      assert hd(item.blocking_dependencies).id == blocker.id
    end

    test "returns stories blocked by epic-level dependencies (no story deps)" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      # Epic 2 depends on Epic 1
      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      # Epic 1 has an unverified story
      _unverified_in_epic_1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_1.id,
          number: "1.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      # Epic 2 has a story with NO story-level deps — but it is still
      # blocked because epic 1 has unverified stories
      story_in_epic_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_2.id,
          number: "2.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_blocked_stories(tenant.id, project_id: project.id)

      blocked_ids = Enum.map(result.data, & &1.story.id)
      assert story_in_epic_2.id in blocked_ids
    end
  end

  describe "get_dependency_graph/2" do
    test "returns full graph with epics, stories, and edges" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      story_1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_1.id, number: "1.1"})
      story_2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_2.id, number: "2.1"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_2.id,
        depends_on_story_id: story_1.id
      })

      {:ok, graph} = Queries.get_dependency_graph(tenant.id, project.id)

      assert length(graph.epics) == 2
      assert length(graph.epic_dependencies) == 1
      assert length(graph.story_dependencies) == 1

      epic_dep = hd(graph.epic_dependencies)
      assert epic_dep.from == epic_2.id
      assert epic_dep.to == epic_1.id

      story_dep = hd(graph.story_dependencies)
      assert story_dep.from == story_2.id
      assert story_dep.to == story_1.id
    end

    test "returns not_found for nonexistent project" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Queries.get_dependency_graph(tenant.id, uuid())
    end

    test "returns not_found for project in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Queries.get_dependency_graph(tenant_a.id, project_b.id)
    end
  end

  # --- Issue 13: Increased pagination limit ---

  describe "list_ready_stories/2 pagination limits" do
    test "default page_size is 100" do
      %{tenant: tenant} = setup_project()

      {:ok, result} = Queries.list_ready_stories(tenant.id)

      assert result.page_size == 100
    end

    test "allows page_size up to 500" do
      %{tenant: tenant} = setup_project()

      {:ok, result} = Queries.list_ready_stories(tenant.id, page_size: 500)

      assert result.page_size == 500
    end

    test "caps page_size at 500 (not 100)" do
      %{tenant: tenant} = setup_project()

      {:ok, result} = Queries.list_ready_stories(tenant.id, page_size: 999)

      assert result.page_size == 500
    end
  end

  describe "list_blocked_stories/2 pagination limits" do
    test "default page_size is 100" do
      %{tenant: tenant} = setup_project()

      {:ok, result} = Queries.list_blocked_stories(tenant.id)

      assert result.page_size == 100
    end

    test "allows page_size up to 500" do
      %{tenant: tenant} = setup_project()

      {:ok, result} = Queries.list_blocked_stories(tenant.id, page_size: 500)

      assert result.page_size == 500
    end
  end

  # --- wb-01 (#245): stable pagination with duplicate sort_key values ---

  describe "list_ready_stories/2 pagination stability (wb-01)" do
    test "paginates deterministically across pages when sort_key ties" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      # 100 ready stories (pending, no deps), all sharing an identical sort_key.
      story_ids =
        for i <- 1..100 do
          story =
            fixture(:story, %{
              tenant_id: tenant.id,
              epic_id: epic.id,
              project_id: project.id,
              number: "1.#{i}",
              agent_status: :pending
            })

          story.id
        end

      force_sort_key(story_ids, 0)

      collected =
        for page <- 1..10 do
          {:ok, result} =
            Queries.list_ready_stories(tenant.id,
              project_id: project.id,
              page: page,
              page_size: 10
            )

          assert result.total == 100,
                 "expected total 100 on page #{page}, got #{result.total}"

          assert length(result.data) == 10,
                 "expected 10 rows on page #{page}, got #{length(result.data)}"

          Enum.map(result.data, & &1.id)
        end

      all_ids = List.flatten(collected)

      assert length(all_ids) == 100,
             "expected 100 rows total across pages, got #{length(all_ids)}"

      unique_ids = Enum.uniq(all_ids)

      assert length(unique_ids) == 100,
             "duplicate/skipped rows across pages: #{length(all_ids) - length(unique_ids)} duplicates"

      assert MapSet.new(unique_ids) == MapSet.new(story_ids),
             "paginated ids did not exactly cover the created stories (skips or duplicates)"
    end

    test "page order is stable across repeated runs when sort_key ties" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story_ids =
        for i <- 1..30 do
          story =
            fixture(:story, %{
              tenant_id: tenant.id,
              epic_id: epic.id,
              project_id: project.id,
              number: "2.#{i}",
              agent_status: :pending
            })

          story.id
        end

      force_sort_key(story_ids, 0)

      fetch_all =
        fn ->
          for page <- 1..3 do
            {:ok, result} =
              Queries.list_ready_stories(tenant.id,
                project_id: project.id,
                page: page,
                page_size: 10
              )

            Enum.map(result.data, & &1.id)
          end
          |> List.flatten()
        end

      assert fetch_all.() == fetch_all.(),
             "row ordering was not stable across identical queries"
    end
  end

  describe "list_blocked_stories/2 pagination stability (wb-01)" do
    test "paginates deterministically across pages when sort_key ties" do
      %{tenant: tenant, project: project} = setup_project()
      prereq_epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      blocked_epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      # blocked_epic depends on prereq_epic, which has an unverified story:
      # every story in blocked_epic is therefore blocked at the epic level.
      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: blocked_epic.id,
        depends_on_epic_id: prereq_epic.id
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: prereq_epic.id,
        project_id: project.id,
        number: "1.1",
        agent_status: :implementing,
        verified_status: :unverified
      })

      story_ids =
        for i <- 1..100 do
          story =
            fixture(:story, %{
              tenant_id: tenant.id,
              epic_id: blocked_epic.id,
              project_id: project.id,
              number: "2.#{i}",
              agent_status: :pending
            })

          story.id
        end

      force_sort_key(story_ids, 0)

      collected =
        for page <- 1..10 do
          {:ok, result} =
            Queries.list_blocked_stories(tenant.id,
              project_id: project.id,
              page: page,
              page_size: 10
            )

          assert result.total == 100,
                 "expected total 100 on page #{page}, got #{result.total}"

          assert length(result.data) == 10,
                 "expected 10 rows on page #{page}, got #{length(result.data)}"

          Enum.map(result.data, & &1.story.id)
        end

      all_ids = List.flatten(collected)

      assert length(all_ids) == 100,
             "expected 100 rows total across pages, got #{length(all_ids)}"

      unique_ids = Enum.uniq(all_ids)

      assert length(unique_ids) == 100,
             "duplicate/skipped rows across pages: #{length(all_ids) - length(unique_ids)} duplicates"

      assert MapSet.new(unique_ids) == MapSet.new(story_ids),
             "paginated ids did not exactly cover the created blocked stories (skips or duplicates)"
    end
  end

  # --- wb-02 (#246): batched blocking-dependency fetch (no N+1) ---

  describe "list_blocked_stories/2 query count (wb-02)" do
    setup do
      %{tenant: tenant, project: project} = setup_project()
      prereq_epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      blocked_epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: blocked_epic.id,
        depends_on_epic_id: prereq_epic.id
      })

      # A story-level blocker too, so both batch queries return rows.
      blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: prereq_epic.id,
          project_id: project.id,
          number: "1.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      %{tenant: tenant, project: project, blocked_epic: blocked_epic, blocker: blocker}
    end

    defp seed_blocked(ctx, %Range{} = range) do
      for i <- range do
        story =
          fixture(:story, %{
            tenant_id: ctx.tenant.id,
            epic_id: ctx.blocked_epic.id,
            project_id: ctx.project.id,
            number: "2.#{i}",
            agent_status: :pending
          })

        fixture(:story_dependency, %{
          tenant_id: ctx.tenant.id,
          story_id: story.id,
          depends_on_story_id: ctx.blocker.id
        })
      end

      :ok
    end

    test "issues a constant number of queries regardless of story count", ctx do
      seed_blocked(ctx, 1..50)

      queries =
        capture_repo_queries(fn ->
          {:ok, result} =
            Queries.list_blocked_stories(ctx.tenant.id,
              project_id: ctx.project.id,
              page_size: 100
            )

          assert result.total == 50
          assert length(result.data) == 50
          # Every story reports its blockers (story-level + epic-level).
          assert Enum.all?(result.data, &(&1.blocking_dependencies != []))
        end)

      count = length(queries)

      # count aggregate + main list + batch story deps + batch epic deps == 4.
      # The buggy version issued 2 extra queries PER story (100+ for 50 stories).
      assert count < 10,
             "expected a small constant query count, got #{count} (N+1 regression?)"
    end

    test "query count does not scale with the number of blocked stories", ctx do
      seed_blocked(ctx, 1..5)

      small =
        capture_repo_queries(fn ->
          Queries.list_blocked_stories(ctx.tenant.id, project_id: ctx.project.id, page_size: 100)
        end)
        |> length()

      # Add many more blocked stories to the same dataset.
      seed_blocked(ctx, 6..50)

      large =
        capture_repo_queries(fn ->
          Queries.list_blocked_stories(ctx.tenant.id, project_id: ctx.project.id, page_size: 100)
        end)
        |> length()

      assert small == large,
             "query count scaled with story count (#{small} for 5 stories vs #{large} for 50) — N+1 regression"
    end
  end
end
