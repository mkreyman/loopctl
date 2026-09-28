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

  # Drive the real migration's down/0 in THIS process. Mirrors Ecto.Migrator's
  # `attempt(.., :forward, :down, :down, ..)` for an explicit down/0 (the raw execute
  # SQL runs forward as written), folding the list back to the old fixed-key map —
  # intentionally lossy.
  defp run_migration_down do
    Runner.run(
      AdminRepo,
      AdminRepo.config(),
      @migration_version,
      ReshapeChannelPostsRefsToList,
      :forward,
      :down,
      :down,
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

  # AC-40.A1.5 fail-soft: an UNEXPECTED stored jsonb SCALAR (only reachable via
  # corruption / a manual write — neither the old map schema nor up/0 can persist it)
  # must NOT raise an Ecto load error that 500s the channel read. RefsList.load/1
  # coerces it to nil (empty ref set) instead of falling through to :error.
  test "RefsList.load fails soft on an unexpected jsonb scalar row (no 500)" do
    post = seed_post_with_raw_refs("i-am-a-scalar-string")

    reloaded = AdminRepo.get!(ChannelPost, post.id)
    assert reloaded.refs == nil
  end

  # Read the RAW stored refs column (bypassing RefsList.load) so a down/0 test can
  # assert the exact folded MAP shape the old schema expects.
  defp raw_refs(post_id) do
    %{rows: [[refs]]} =
      AdminRepo.query!(
        "SELECT refs FROM channel_posts WHERE id = $1",
        [Ecto.UUID.dump!(post_id)]
      )

    refs
  end

  # down/0 restores the OLD fixed-key-map shape. It is INTENTIONALLY LOSSY: the
  # optional label is dropped and items sharing a type collapse to the last value —
  # the old map could never hold those. This documents the accepted lossiness.
  test "down/0 folds the list back to a map, dropping label (intentionally lossy)" do
    post =
      seed_post_with_raw_refs([
        %{"type" => "pr", "value" => "107", "label" => "the fix"},
        %{"type" => "file", "value" => "lib/a.ex:42"}
      ])

    assert :ok = run_migration_down()

    # type -> value only; label is gone.
    assert raw_refs(post.id) == %{"pr" => "107", "file" => "lib/a.ex:42"}
  end

  # down/0 on multiple items sharing a type keeps the LAST value (jsonb_object_agg
  # collapses duplicate keys) — the documented lossy collapse the old map forces.
  test "down/0 collapses duplicate types to the last value (lossy expansion reverse)" do
    post =
      seed_post_with_raw_refs([
        %{"type" => "file", "value" => "a"},
        %{"type" => "file", "value" => "b"}
      ])

    assert :ok = run_migration_down()

    assert raw_refs(post.id) == %{"file" => "b"}
  end

  # A corrupt item whose `type` is JSON null (key present, value null) previously
  # crashed jsonb_object_agg ("field name must not be null"), aborting the whole
  # rollback. The `WHERE item ->> 'type' IS NOT NULL` guard skips it so down/0
  # completes, folding only the well-formed items.
  test "down/0 skips a JSON-null type item instead of crashing the rollback" do
    post =
      seed_post_with_raw_refs([
        %{"type" => nil, "value" => "orphan"},
        %{"type" => "pr", "value" => "5"}
      ])

    assert :ok = run_migration_down()

    assert raw_refs(post.id) == %{"pr" => "5"}
  end
end
