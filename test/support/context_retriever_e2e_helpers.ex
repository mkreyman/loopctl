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

  The `marker` argument to `sweep_marker_tenants/1` and `commit_tenant/1` is the
  per-suite slug prefix (e.g. `"crjourney-"`, `"crsec-"`) so each suite's
  committed tenants are swept independently. See either suite's moduledoc for
  WHY a committed tenant + `async: false` are required.
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

  @doc "Deletes every committed tenant whose slug starts with `marker` (module-boundary cleanup)."
  def sweep_marker_tenants(marker) do
    Sandbox.unboxed_run(AdminRepo, fn ->
      AdminRepo.delete_all(from(t in Tenant, where: like(t.slug, ^"#{marker}%")))
    end)
  end

  @doc """
  Inserts a committed, human-anchored tenant visible to BOTH the AdminRepo auth
  path and the Repo executor path. Slug is prefixed with `marker` so it is swept
  at module boundaries.
  """
  def commit_tenant(marker) do
    seq = System.unique_integer([:positive])
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
