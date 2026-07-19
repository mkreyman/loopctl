defmodule Loopctl.Repo.ReshapeChannelPostsRefsMigrationTest do
  @moduledoc """
  US-40.A1 / TC-40.A1.7 — the data migration
  `ReshapeChannelPostsRefsToList` reshapes any existing stored `refs` MAP
  (`{file, pr}`) into the typed-open LIST form
  (`[{type: file, value: ...}, {type: pr, value: ...}]`) so no live row breaks
  when `field :refs` becomes the `RefsList` custom type.

  We seed a row, then stamp its `refs` column with the OLD map shape via raw SQL
  (the changeset now rejects a map, so we bypass it), run the migration's `up`
  transformation, and assert the row is now the list — with a STABLE item order
  (`ORDER BY key`, so `file` precedes `pr`).
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost

  # Mirrors ReshapeChannelPostsRefsToList.up/0 exactly (a data migration's UPDATE),
  # run inside the test transaction against the seeded old-shape row. Kept in sync
  # with priv/repo/migrations/20260718010000_reshape_channel_posts_refs_to_list.exs.
  @reshape_up """
  UPDATE channel_posts
  SET refs = (
    SELECT jsonb_agg(jsonb_build_object('type', key, 'value', value) ORDER BY key)
    FROM jsonb_each_text(refs)
  )
  WHERE refs IS NOT NULL
    AND jsonb_typeof(refs) = 'object'
    AND refs <> '{}'::jsonb
  """

  test "reshapes an existing refs map into the typed-open list, order stable" do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {:ok, post} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => "seed"})

    # Stamp the OLD fixed-key MAP shape directly into the jsonb column. Pass an
    # Elixir MAP (not a JSON string) so Postgrex encodes a jsonb OBJECT — a text
    # param would be double-encoded into a jsonb string scalar.
    %{num_rows: 1} =
      AdminRepo.query!(
        "UPDATE channel_posts SET refs = $1 WHERE id = $2",
        [%{"file" => "x", "pr" => "1"}, Ecto.UUID.dump!(post.id)]
      )

    # Run the migration's reshape transformation — it matches our object row.
    %{num_rows: reshaped} = AdminRepo.query!(@reshape_up)
    assert reshaped >= 1

    # Read back through the schema (RefsList.load) — the row now loads as the list.
    reloaded = AdminRepo.get!(ChannelPost, post.id)

    # file precedes pr (ORDER BY key), values preserved.
    assert reloaded.refs == [
             %{"type" => "file", "value" => "x"},
             %{"type" => "pr", "value" => "1"}
           ]
  end
end
