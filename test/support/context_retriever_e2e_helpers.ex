defmodule Loopctl.ContextRetrieverE2EHelpers do
  @moduledoc """
  Shared committed-tenant scaffolding for the Epic 30 Context Retriever
  end-to-end suites (`test/e2e/context_retriever_journey_test.exs` and
  `test/e2e/context_retriever_security_test.exs`).

  These helpers single-source the SECURITY-CRITICAL setup those suites depend on
  so its semantics cannot silently drift between them:

    * the two-connection, cross-repo tenant visibility (the AdminRepo auth path
      AND the `Loopctl.Repo` executor path must both see the tenant), which is
      why the tenant is inserted via `Sandbox.unboxed_run/2` (a committed
      connection) rather than the boxed sandbox;
    * the slug-marker tenant sweep at module boundaries;
    * seeding backing rows on the `Loopctl.Repo` connection the RLS-scoped
      executor (`Repo.with_tenant/2`, `SET LOCAL ROLE loopctl_app`) reads.

  The `base` argument to `sweep_marker_tenants/1` and `commit_tenant/1` is the
  per-suite slug prefix (e.g. `"crjourney-"`, `"crsec-"`) so each suite's
  committed tenants are swept independently. Internally each base is narrowed to
  a PER-RUN marker (`base <> run_nonce <> "-"`, see `run_marker/1`) so the
  BYPASSRLS sweep only ever deletes tenants THIS run created. See either suite's
  moduledoc for WHY a committed tenant + `async: false` are required.

  ## Why the sweep is run-scoped (not just prefix-scoped)

  `sweep_marker_tenants/1` runs `AdminRepo.delete_all` (BYPASSRLS) over COMMITTED
  tenants at each suite's `setup_all`/`on_exit`. A static prefix (`"crsec-%"`)
  is safe within ONE run — the e2e suites are `async: false` and per-tenant slugs
  carry a `System.unique_integer` suffix — but NOT across two runs sharing one
  physical Postgres (parallel CI jobs, or a dev running e2e while CI does): one
  run's `setup_all` sweep would delete the other run's live tenants mid-flight,
  orphaning committed api_keys/agents/stories into FK-failure flakiness. Narrowing
  the marker to `run_marker/1` (the BEAM's OS pid — stable within a `mix test`
  run, distinct across concurrent runs) confines every sweep to the tenants the
  current run committed.
  """

  import Ecto.Query
  import Loopctl.Fixtures
  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Conn, only: [put_req_header: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  @doc """
  Narrows a per-suite slug `base` (e.g. `"crsec-"`) to a PER-RUN marker
  (`base <> os_pid <> "-"`). `System.pid/0` is the BEAM's OS process id: one per
  `mix test` invocation (shared by every suite in that run) and distinct across
  concurrent runs sharing a physical Postgres — so the BYPASSRLS sweep never
  clobbers another run's live committed tenants. The pid is digits-only, keeping
  the slug within `Tenant`'s `^[a-z0-9][a-z0-9-]*[a-z0-9]$` / 63-char rules.
  """
  def run_marker(base), do: "#{base}#{System.pid()}-"

  @doc "Deletes every committed tenant this RUN created under `base` (module-boundary cleanup)."
  def sweep_marker_tenants(base) do
    marker = run_marker(base)

    Sandbox.unboxed_run(AdminRepo, fn ->
      AdminRepo.delete_all(from(t in Tenant, where: like(t.slug, ^"#{marker}%")))
    end)
  end

  @doc """
  Inserts a committed, human-anchored tenant visible to BOTH the AdminRepo auth
  path and the Repo executor path. Slug carries the per-run marker (`base` scoped
  by `run_marker/1`) so it is swept only by THIS run's `sweep_marker_tenants/1`.
  """
  def commit_tenant(base) do
    seq = System.unique_integer([:positive])
    marker = run_marker(base)
    id = Ecto.UUID.generate()

    Sandbox.unboxed_run(AdminRepo, fn ->
      %Tenant{}
      |> Tenant.create_changeset(%{
        name: "T#{seq}",
        slug: "#{marker}#{seq}",
        email: "#{marker}#{seq}@example.com"
      })
      |> Ecto.Changeset.put_change(:id, id)
      |> Ecto.Changeset.put_change(:trust_tier, :human_anchored)
      |> AdminRepo.insert!()
    end)

    AdminRepo.get!(Tenant, id)
  end

  @doc "Returns a raw `:user`-role API key for `tenant_id`."
  def user_key(tenant_id) do
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :user})
    raw
  end

  @doc "Returns a raw `:agent`-role API key (with a backing agent) for `tenant_id`."
  def agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    raw
  end

  @doc "Seeds a project on the Repo connection the executor reads."
  def seed_project(tenant_id, attrs \\ %{}) do
    %Project{tenant_id: tenant_id}
    |> Project.create_changeset(build(:project, attrs))
    |> Repo.insert!()
  end

  @doc "Seeds an epic under `project_id`."
  def seed_epic(tenant_id, project_id) do
    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(build(:epic, %{}))
    |> Repo.insert!()
  end

  @doc "Seeds a story (auto-creating its parent project + epic) with `attrs`."
  def seed_story(tenant_id, attrs) do
    project = seed_project(tenant_id)
    epic = seed_epic(tenant_id, project.id)

    %Story{tenant_id: tenant_id, project_id: project.id, epic_id: epic.id}
    |> Story.create_changeset(build(:story, attrs))
    |> Repo.insert!()
  end

  @doc "Adds the `Authorization: Bearer <raw_key>` header to `conn`."
  def auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  @doc """
  A fresh conn carrying the witness STH header (each dispatched request needs its
  own conn).
  """
  def fresh_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")
end
