defmodule Loopctl.Repo.RunnerAgentBackfillMigrationTest do
  @moduledoc """
  Issue #803 — the BACKFILL in `20260920100000_add_agent_id_to_runners.exs`.

  The rule the backfill has to obey is the one `Loopctl.Runners.runner_agent/2` obeys, and the
  two live in different languages with nothing binding them: **never adopt an agent this code
  did not create.** `AgentController`'s `:register` is `exact_role: :agent`, so any agent-role
  key in a tenant can create `runner:minis` before a deploy, and the first version of this
  migration would have bound the existing runner to that row — after which
  `previous_runner_agent/2` cements it for ever, because reuse in the application is decided by
  a PREVIOUS RUNNER ROW. The migration runs first, so the migration is the half that decides.

  This is also the only test that can reach the backfill at all: it runs once, against rows
  that existed before the column did, and by the time the suite boots the column is NOT NULL
  and every runner already has an agent.

  ## How the migration is driven

  The files under `priv/repo/migrations` are not compiled into the app, so this one is loaded
  at runtime and driven with `Ecto.Migration.Runner.run/9` directly — the same entry point
  `Ecto.Migrator.attempt/7` uses — rather than `Ecto.Migrator.up/down`, which spawns a Task
  with its own transaction and lock that cannot check out the sandbox-owned connection.
  Running it in THIS process puts the DDL inside the sandbox transaction, so the whole
  down → seed → up sequence is rolled back on exit and the suite's own `runners` table is
  untouched. The pattern is `Loopctl.Repo.MemoryStoresRollbackTest`'s.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo

  @version 20_260_920_100_000
  @migrations_dir Path.join([File.cwd!(), "priv", "repo", "migrations"])

  migration_file = Path.wildcard(Path.join(@migrations_dir, "#{@version}_*.exs")) |> hd()
  Code.require_file(migration_file)

  alias Loopctl.Repo.Migrations.AddAgentIdToRunners

  setup do
    pid = Sandbox.start_owner!(AdminRepo)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Back to the pre-column world, which is the only state the backfill ever sees.
    migrate(:down)
    :ok
  end

  test "binds each runner to an agent it created, and never to a squatter's" do
    tenant = insert_tenant()

    # `minis` — an agent-role key got there first and holds the preferred name.
    squatter = insert_agent(tenant, "runner:minis")
    minis = insert_runner(tenant, "minis")

    # `blockit` — nobody in the way.
    blockit = insert_runner(tenant, "blockit")

    migrate(:up)

    minis_agent = agent_of(minis)
    refute minis_agent == squatter, "the backfill adopted a squatter's agent"
    assert name_of(minis_agent) == "runner:minis-#{minis}"

    assert name_of(agent_of(blockit)) == "runner:blockit"

    # And the squatter's row is untouched — the backfill takes nothing over, it only adds.
    assert name_of(squatter) == "runner:minis"
  end

  test "two runners of the same name in DIFFERENT tenants each get their own agent" do
    tenant_a = insert_tenant()
    tenant_b = insert_tenant()

    a = insert_runner(tenant_a, "minis")
    b = insert_runner(tenant_b, "minis")

    migrate(:up)

    # The unique index is `(tenant_id, name)`, so neither is a conflict for the other and both
    # take the preferred name. A backfill that keyed on the name alone would have given one of
    # them the other tenant's agent — a cross-tenant binding, which is worse than a squat.
    assert name_of(agent_of(a)) == "runner:minis"
    assert name_of(agent_of(b)) == "runner:minis"
    refute agent_of(a) == agent_of(b)
  end

  # --- driving the migration ------------------------------------------------------------

  defp migrate(:up) do
    Runner.run(AdminRepo, AdminRepo.config(), @version, AddAgentIdToRunners, :forward, :up, :up,
      log: false
    )
  end

  defp migrate(:down) do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @version,
      AddAgentIdToRunners,
      :forward,
      :down,
      :down,
      log: false
    )
  end

  # --- seeding, in SQL ------------------------------------------------------------------
  #
  # Raw inserts rather than schemas and fixtures: `Loopctl.Runners.Runner` declares `agent_id`,
  # and inside `setup` that column does not exist. A schema insert would fail on a column the
  # pre-migration world has not got, which is exactly the world under test.

  defp insert_tenant do
    id = Ecto.UUID.generate()
    seq = System.unique_integer([:positive])

    AdminRepo.query!(
      """
      INSERT INTO tenants (id, name, slug, email, status, inserted_at, updated_at)
      VALUES ($1::uuid, $2, $3, $4, 'active', now(), now())
      """,
      [Ecto.UUID.dump!(id), "backfill #{seq}", "backfill-#{seq}", "backfill-#{seq}@example.com"]
    )

    id
  end

  defp insert_agent(tenant_id, name) do
    id = Ecto.UUID.generate()

    AdminRepo.query!(
      """
      INSERT INTO agents (id, tenant_id, name, agent_type, status, last_seen_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, 'implementer', 'active', now(), now(), now())
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(tenant_id), name]
    )

    id
  end

  defp insert_runner(tenant_id, name) do
    id = Ecto.UUID.generate()
    key_id = insert_api_key(tenant_id, name)

    AdminRepo.query!(
      """
      INSERT INTO runners (id, tenant_id, api_key_id, name, max_sessions, in_flight, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4, 2, 0, now(), now())
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(tenant_id), Ecto.UUID.dump!(key_id), name]
    )

    id
  end

  defp insert_api_key(tenant_id, name) do
    id = Ecto.UUID.generate()
    seq = System.unique_integer([:positive])

    AdminRepo.query!(
      """
      INSERT INTO api_keys (id, tenant_id, name, role, key_hash, key_prefix, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, 'agent', $4, $5, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(tenant_id),
        "runner:#{name}",
        "hash-#{seq}",
        "lc_bf#{seq}"
      ]
    )

    id
  end

  defp agent_of(runner_id) do
    %{rows: [[agent_id]]} =
      AdminRepo.query!("SELECT agent_id FROM runners WHERE id = $1::uuid", [
        Ecto.UUID.dump!(runner_id)
      ])

    Ecto.UUID.load!(agent_id)
  end

  defp name_of(agent_id) do
    %{rows: [[name]]} =
      AdminRepo.query!("SELECT name FROM agents WHERE id = $1::uuid", [
        Ecto.UUID.dump!(agent_id)
      ])

    name
  end
end
