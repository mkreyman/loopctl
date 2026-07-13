defmodule Loopctl.WorkBreakdown.StoriesRlsPilotTest do
  @moduledoc """
  US-33.7 — RELEASE-GATE integration tests for the flag-guarded RLS-Repo reroute
  pilot on `Loopctl.WorkBreakdown.Stories.list_stories_by_project/3`.

  This is a SECURITY-BOUNDARY change: the parity, tenant-isolation, and fail-closed
  tests below are gates, not nice-to-haves.

  ## Why `async: false` + dual-repo seeding

  The RLS path reads through `Loopctl.Repo.with_tenant/2` (an RLS transaction that
  runs `SET LOCAL ROLE loopctl_app`, a NON-BYPASSRLS role — see config/test.exs
  `:rls_role`). RLS only genuinely enforces when the read runs on the same
  connection the rows were seeded on, under that non-owner role — which requires
  the SHARED sandbox (`async: false`). This mirrors
  `test/loopctl/context_retriever/executor_test.exs`.

  `Loopctl.Repo` and `Loopctl.AdminRepo` are SEPARATE sandbox connections over the
  same physical DB, so a row seeded via one is invisible to the other's
  transaction. The AdminRepo path (default) reads AdminRepo's copy; the RLS path
  reads Repo's copy. Seeding the SAME primary keys into both repos is impossible
  here: both sandbox transactions stay open for the whole test, so a duplicate-PK
  insert into the second repo blocks on the first's uncommitted row lock until
  `statement_timeout` cancels it. The parity test therefore seeds the SAME LOGICAL
  rows (identical story `number`/`title`, hence identical `sort_key`/ordering) into
  BOTH repos under per-repo ids, and asserts the two code paths return identical
  ordered row sets by business key + identical totals. It additionally asserts the
  RLS path returns EXACTLY the story ids seeded into `Repo`, so id-level
  correctness of the RLS path is proven directly. Isolation/fail-closed tests seed
  via `Repo` only (the connection the RLS path reads on) so RLS is actually
  exercised.
  """
  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  # --- Explicit-id seeding helpers (see moduledoc) ---

  defp seed_tenant(repo, id) do
    seq = System.unique_integer([:positive])

    %Tenant{id: id}
    |> Tenant.create_changeset(%{
      name: "RLS Pilot Tenant #{seq}",
      slug: "rls-pilot-#{seq}",
      email: "rls-pilot-#{seq}@example.com",
      status: :active
    })
    |> repo.insert!()
  end

  defp seed_project(repo, tenant_id, id) do
    %Project{id: id, tenant_id: tenant_id}
    |> Project.create_changeset(build(:project))
    |> repo.insert!()
  end

  defp seed_epic(repo, tenant_id, project_id, id) do
    %Epic{id: id, tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(build(:epic))
    |> repo.insert!()
  end

  defp seed_story(repo, tenant_id, project_id, epic_id, attrs) do
    %Story{id: uuid(), tenant_id: tenant_id, project_id: project_id, epic_id: epic_id}
    |> Story.create_changeset(build(:story, attrs))
    |> repo.insert!()
  end

  # Seeds one tenant/project/epic (per-repo ids to avoid duplicate-PK lock
  # contention across the two open sandbox transactions) plus the given logical
  # stories into `repo`. Returns `{ids, [%Story{}]}` so a caller can assert exact
  # returned ids for the repo it seeded.
  defp seed_tree(repo, story_specs) do
    ids = %{tenant: uuid(), project: uuid(), epic: uuid()}

    seed_tenant(repo, ids.tenant)
    seed_project(repo, ids.tenant, ids.project)
    seed_epic(repo, ids.tenant, ids.project, ids.epic)

    stories =
      for spec <- story_specs do
        seed_story(repo, ids.tenant, ids.project, ids.epic, %{
          number: spec.number,
          title: spec.title
        })
      end

    {ids, stories}
  end

  # Business-key projection of a result page (the fields that drive ordering) so
  # parity is asserted on logical row identity + ordering across two repos whose
  # physical ids necessarily differ.
  defp business_keys(%{data: data}) do
    Enum.map(data, &{&1.number, &1.title, &1.sort_key})
  end

  describe "TC-33.7.1 — RLS path returns identical rows to the AdminRepo path (same tenant)" do
    test "same tenant: RLS row set matches AdminRepo path and returns exactly its seeded ids" do
      story_specs = [
        %{number: "1.3", title: "Third"},
        %{number: "1.1", title: "First"},
        %{number: "1.2", title: "Second"}
      ]

      # Same LOGICAL rows in both repo transactions (per-repo ids).
      {admin_ids, _admin_stories} = seed_tree(AdminRepo, story_specs)
      {rls_ids, rls_stories} = seed_tree(Repo, story_specs)

      assert {:ok, admin_page} =
               Stories.list_stories_by_project(admin_ids.tenant, admin_ids.project,
                 strategy: :admin
               )

      assert {:ok, rls_page} =
               Stories.list_stories_by_project(rls_ids.tenant, rls_ids.project, strategy: :rls)

      # Identical totals and identical ordered logical row sets.
      assert admin_page.total == 3
      assert rls_page.total == admin_page.total
      assert business_keys(rls_page) == business_keys(admin_page)

      # The ordering contract (asc: sort_key) holds on the RLS path.
      assert Enum.map(rls_page.data, & &1.number) == ["1.1", "1.2", "1.3"]

      # Id-level correctness: the RLS path returns EXACTLY the rows seeded into Repo
      # (by id), in sort order — not a superset, not a different tenant's rows.
      expected_ids =
        rls_stories
        |> Enum.sort_by(& &1.sort_key)
        |> Enum.map(& &1.id)

      assert Enum.map(rls_page.data, & &1.id) == expected_ids
    end

    test "parity holds under pagination (limit/offset) on the RLS path" do
      story_specs = for n <- 1..5, do: %{number: "1.#{n}", title: "Story #{n}"}

      {admin_ids, _} = seed_tree(AdminRepo, story_specs)
      {rls_ids, _} = seed_tree(Repo, story_specs)

      assert {:ok, admin_page} =
               Stories.list_stories_by_project(admin_ids.tenant, admin_ids.project,
                 strategy: :admin,
                 limit: 2,
                 offset: 2
               )

      assert {:ok, rls_page} =
               Stories.list_stories_by_project(rls_ids.tenant, rls_ids.project,
                 strategy: :rls,
                 limit: 2,
                 offset: 2
               )

      assert rls_page.total == 5
      assert admin_page.total == 5
      assert rls_page.limit == 2
      assert rls_page.offset == 2
      assert business_keys(rls_page) == business_keys(admin_page)
      assert Enum.map(rls_page.data, & &1.number) == ["1.3", "1.4"]
    end
  end

  describe "TC-33.7.2 — RLS path enforces tenant isolation" do
    test "tenant A never sees tenant B's rows via the RLS path" do
      {ids_a, _} = seed_tree(Repo, [%{number: "1.1", title: "Alpha only"}])
      {ids_b, _} = seed_tree(Repo, [%{number: "1.1", title: "Beta only"}])

      # Read as tenant A via the RLS path: only tenant A's row, enforced by RLS
      # (SET LOCAL ROLE loopctl_app + current_tenant_id) AND the explicit predicate.
      assert {:ok, page} =
               Stories.list_stories_by_project(ids_a.tenant, ids_a.project, strategy: :rls)

      assert page.total == 1
      assert Enum.map(page.data, & &1.title) == ["Alpha only"]
      refute Enum.any?(page.data, &(&1.tenant_id == ids_b.tenant))
    end

    test "tenant A cannot read tenant B's project via the RLS path (cross-tenant project id)" do
      {ids_a, _} = seed_tree(Repo, [%{number: "1.1", title: "Alpha"}])
      {ids_b, _} = seed_tree(Repo, [%{number: "1.1", title: "Beta"}])

      # Tenant A asks for tenant B's project_id — RLS + predicate yield nothing,
      # never tenant B's rows.
      assert {:ok, page} =
               Stories.list_stories_by_project(ids_a.tenant, ids_b.project, strategy: :rls)

      assert page.total == 0
      assert page.data == []
    end
  end

  describe "TC-33.7.3 — RLS path fails closed on missing/blank tenant context" do
    test "nil tenant context yields zero rows, never cross-tenant rows or a leaking error" do
      {ids, _} = seed_tree(Repo, [%{number: "1.1", title: "Present"}])

      assert {:ok, page} =
               Stories.list_stories_by_project(nil, ids.project, strategy: :rls)

      assert page.total == 0
      assert page.data == []
    end

    test "blank tenant context yields zero rows (no CastError leak)" do
      {ids, _} = seed_tree(Repo, [%{number: "1.1", title: "Present"}])

      assert {:ok, page} =
               Stories.list_stories_by_project("", ids.project, strategy: :rls)

      assert page.total == 0
      assert page.data == []
    end
  end

  describe "TC-33.7.4 — flag default routes to the AdminRepo path unchanged" do
    test "default config (flag off) behaves identically to an explicit :admin call" do
      # The test config leaves :rls_reroute_list_stories_by_project at its default
      # (false), so a call with NO :strategy opt must resolve to the AdminRepo path.
      assert Application.get_env(:loopctl, :rls_reroute_list_stories_by_project, false) == false

      # Seed only via AdminRepo (the path the default must take).
      {ids, _} =
        seed_tree(AdminRepo, [
          %{number: "1.1", title: "First"},
          %{number: "1.2", title: "Second"}
        ])

      assert {:ok, default_page} =
               Stories.list_stories_by_project(ids.tenant, ids.project)

      assert {:ok, explicit_admin_page} =
               Stories.list_stories_by_project(ids.tenant, ids.project, strategy: :admin)

      assert default_page == explicit_admin_page
      assert default_page.total == 2
      assert Enum.map(default_page.data, & &1.number) == ["1.1", "1.2"]
    end
  end
end
