defmodule Loopctl.WorkBreakdown.QueriesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.WorkBreakdown.Queries

  defp setup_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project}
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

  # --- wb-01: stable pagination with a unique secondary sort key ---
  #
  # sort_key is computed from the story number (major*10000 + minor*10) and is
  # NOT unique — two stories numbered "1.1" in different projects share it. With
  # OFFSET pagination and NO project_id filter, rows sharing a sort_key on a page
  # boundary get skipped or duplicated across pages unless a unique tiebreaker
  # (asc: s.id) is appended. These tests would fail on the pre-fix order_by.

  # Collect every page of a paginated query and return the flat list of ids.
  defp collect_all_pages(fun, page_size) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while([], fn page, acc ->
      {:ok, %{data: data}} = fun.(page, page_size)
      ids = Enum.map(data, & &1.id)
      new_acc = acc ++ ids

      if length(data) < page_size do
        {:halt, new_acc}
      else
        {:cont, new_acc}
      end
    end)
  end

  describe "wb-01: paginated ready/blocked stories have a unique tiebreaker" do
    test "list_ready_stories paginates cleanly across projects sharing sort_key" do
      tenant = fixture(:tenant)

      # 5 ready stories all numbered "1.1" across 5 projects -> identical
      # sort_key (10010). No project_id filter => all returned together.
      ready_ids =
        for _ <- 1..5 do
          project = fixture(:project, %{tenant_id: tenant.id})
          epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

          story =
            fixture(:story, %{
              tenant_id: tenant.id,
              epic_id: epic.id,
              project_id: project.id,
              number: "1.1",
              agent_status: :pending
            })

          story.id
        end

      # Sanity: every story shares the same non-unique sort_key.
      assert Enum.uniq(ready_ids) == ready_ids

      collected =
        collect_all_pages(&Queries.list_ready_stories(tenant.id, page: &1, page_size: &2), 2)

      # No skips, no duplicates: the union covers every story exactly once.
      assert length(collected) == 5
      assert MapSet.new(collected) == MapSet.new(ready_ids)
    end

    test "list_blocked_stories paginates cleanly across projects sharing sort_key" do
      tenant = fixture(:tenant)

      # 5 blocked stories all numbered "1.2" across 5 projects -> identical
      # sort_key (10020), each blocked by an unverified story-level dependency.
      blocked_ids =
        for _ <- 1..5 do
          project = fixture(:project, %{tenant_id: tenant.id})
          epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

          blocker =
            fixture(:story, %{
              tenant_id: tenant.id,
              epic_id: epic.id,
              project_id: project.id,
              number: "1.1",
              agent_status: :implementing,
              verified_status: :unverified
            })

          blocked =
            fixture(:story, %{
              tenant_id: tenant.id,
              epic_id: epic.id,
              project_id: project.id,
              number: "1.2",
              agent_status: :pending
            })

          fixture(:story_dependency, %{
            tenant_id: tenant.id,
            story_id: blocked.id,
            depends_on_story_id: blocker.id
          })

          blocked.id
        end

      collected =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.reduce_while([], fn page, acc ->
          {:ok, %{data: data}} = Queries.list_blocked_stories(tenant.id, page: page, page_size: 2)
          ids = Enum.map(data, & &1.story.id)
          new_acc = acc ++ ids
          if length(data) < 2, do: {:halt, new_acc}, else: {:cont, new_acc}
        end)

      assert length(collected) == 5
      assert MapSet.new(collected) == MapSet.new(blocked_ids)
    end
  end

  # --- wb-02: list_blocked_stories batches blocker lookups (no N+1) ---

  # Counts SELECT queries issued through AdminRepo *from this test process* while
  # `fun` runs. The telemetry handler is global and executes in the process that
  # emitted the query, so we scope to `test_pid` to avoid counting queries from
  # other concurrently-running async tests (max_cases > 1).
  defp count_select_queries(fun) do
    ref = :counters.new(1, [:write_concurrency])
    handler_id = "wb02-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:loopctl, :admin_repo, :query],
      fn _event, _measurements, %{query: query}, counter ->
        if self() == test_pid and String.contains?(query, "SELECT") do
          :counters.add(counter, 1, 1)
        end
      end,
      ref
    )

    try do
      result = fun.()
      {result, :counters.get(ref, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  # Creates `n` blocked stories in one project, each with a story-level blocker.
  defp seed_blocked_stories(tenant, project, n) do
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    for i <- 1..n do
      blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          project_id: project.id,
          number: "#{i}.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      blocked =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          project_id: project.id,
          number: "#{i}.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked.id,
        depends_on_story_id: blocker.id
      })

      blocked.id
    end
  end

  describe "wb-02: list_blocked_stories does not issue O(page_size) queries" do
    test "query count is bounded and does not scale with the number of blocked stories" do
      tenant = fixture(:tenant)
      project_small = fixture(:project, %{tenant_id: tenant.id})
      project_large = fixture(:project, %{tenant_id: tenant.id})

      seed_blocked_stories(tenant, project_small, 2)
      seed_blocked_stories(tenant, project_large, 10)

      {{:ok, small}, q_small} =
        count_select_queries(fn ->
          Queries.list_blocked_stories(tenant.id, project_id: project_small.id, page_size: 500)
        end)

      {{:ok, large}, q_large} =
        count_select_queries(fn ->
          Queries.list_blocked_stories(tenant.id, project_id: project_large.id, page_size: 500)
        end)

      assert length(small.data) == 2
      assert length(large.data) == 10

      # Constant, small query count regardless of page size. The pre-fix code
      # issued 2 + 2*N queries (24 for N=10); batching keeps it at a handful.
      assert q_small == q_large
      assert q_large <= 6
    end

    test "each blocked story still receives its exact blocking dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      # Epic 2 depends on Epic 1, which has an unverified story.
      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic2.id,
        depends_on_epic_id: epic1.id
      })

      epic1_blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic1.id,
          project_id: project.id,
          number: "1.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      story_blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic2.id,
          project_id: project.id,
          number: "2.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      # Blocked by BOTH a story-level dep AND its epic-level dep -> the batched
      # result must combine the two, preserving the pre-fix shape.
      blocked =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic2.id,
          project_id: project.id,
          number: "2.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked.id,
        depends_on_story_id: story_blocker.id
      })

      {:ok, result} = Queries.list_blocked_stories(tenant.id, project_id: project.id)

      item = Enum.find(result.data, &(&1.story.id == blocked.id))
      refute is_nil(item)

      blocker_ids = MapSet.new(item.blocking_dependencies, & &1.id)
      assert blocker_ids == MapSet.new([story_blocker.id, epic1_blocker.id])
    end
  end
end
