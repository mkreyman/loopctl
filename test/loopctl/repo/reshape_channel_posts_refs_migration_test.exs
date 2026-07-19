defmodule Loopctl.Repo.ReshapeChannelPostsRefsMigrationTest do
  @moduledoc """
  US-40.A1 / TC-40.A1.7 — the data migration
  `ReshapeChannelPostsRefsToList` reshapes any existing stored `refs` MAP
  (`{file, pr}`) into the typed-open LIST form
  (`[{type: file, value: ...}, {type: pr, value: ...}]`) so no live row breaks
  when `field :refs` becomes the `RefsList` custom type.

  We seed a row, stamp its `refs` column with the OLD map shape via raw SQL (the
  changeset now rejects a map, so we bypass it), then drive the REAL migration
  module's `up/0` and assert the row is now the list.

  ## How the migration is driven

  The migration file under `priv/repo/migrations` is not compiled into the app, so
  it is loaded here at runtime (`Code.require_file`) and driven with
  `Ecto.Migration.Runner.run/8` DIRECTLY — the same entry point
  `Ecto.Migrator.attempt/7` uses — rather than via `Ecto.Migrator.up`. `Runner.run`
  performs the operation in THIS process, so the UPDATE executes inside the sandbox
  transaction (and is rolled back on exit) instead of a spawned Task under its own
  transaction/lock that could not check out the sandbox-owned connection. This
  exercises the SHIPPED `up/0` verbatim (single source of truth), so a defect edited
  into the migration file WILL fail this test — unlike a hand-copied SQL heredoc.
  """
  use Loopctl.DataCase, async: true

  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost

  @migration_version 20_260_718_010_000
  @migration_file Path.wildcard(
                    Path.join([
                      File.cwd!(),
                      "priv",
                      "repo",
                      "migrations",
                      "#{@migration_version}_*.exs"
                    ])
                  )
                  |> hd()

  Code.require_file(@migration_file)

  alias Loopctl.Repo.Migrations.ReshapeChannelPostsRefsToList

  # Drive the real migration's up/0 in THIS process (mirrors Ecto.Migrator.attempt/7
  # for an explicit up/0 running :forward), so the UPDATE runs inside the sandbox
  # transaction against the seeded row.
  defp run_migration_up do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @migration_version,
      ReshapeChannelPostsRefsToList,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  # Seed a valid post, then stamp its `refs` column with an arbitrary raw jsonb
  # value (an Elixir term Postgrex encodes as jsonb — a MAP for the old object shape,
  # never a JSON string which would double-encode into a jsonb string scalar).
  defp seed_post_with_raw_refs(raw_refs) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {:ok, post} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "seed"})

    %{num_rows: 1} =
      AdminRepo.query!(
        "UPDATE channel_posts SET refs = $1 WHERE id = $2",
        [raw_refs, Ecto.UUID.dump!(post.id)]
      )

    post
  end

  test "reshapes an existing refs map into the typed-open list, order stable" do
    post = seed_post_with_raw_refs(%{"file" => "x", "pr" => "1"})

    assert :ok = run_migration_up()

    # Read back through the schema (RefsList.load) — the row now loads as the list.
    reloaded = AdminRepo.get!(ChannelPost, post.id)

    # file precedes pr (ORDER BY key), values preserved.
    assert reloaded.refs == [
             %{"type" => "file", "value" => "x"},
             %{"type" => "pr", "value" => "1"}
           ]
  end

  # AC-40.A1.5 — a legacy EMPTY map (`{}`) was a valid persistable value under the
  # old fixed-key-map shape. The migration must normalise it to an empty list `[]`;
  # skipping it (as the original `refs <> '{}'` guard did) leaves a row the RefsList
  # type cannot load, which would 500 the whole channel read.
  test "normalises a legacy empty-map row to an empty list (does not skip it)" do
    post = seed_post_with_raw_refs(%{})

    assert :ok = run_migration_up()

    reloaded = AdminRepo.get!(ChannelPost, post.id)
    assert reloaded.refs == []
  end

  # Defense-in-depth: even WITHOUT the migration, a legacy map row must not crash the
  # schema load (one un-loadable row denies the coordination bus). RefsList.load/1
  # coerces the map to the list form.
  test "RefsList.load coerces a legacy empty-map row without the migration" do
    post = seed_post_with_raw_refs(%{})

    # No migration run here — load must still succeed.
    reloaded = AdminRepo.get!(ChannelPost, post.id)
    assert reloaded.refs == []
  end
end
