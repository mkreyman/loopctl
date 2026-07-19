defmodule Loopctl.Repo.Migrations.ReshapeChannelPostsRefsToList do
  @moduledoc """
  US-40.A1: reshape `channel_posts.refs` from a fixed-key MAP
  (`{file,pr,branch,commit}`) to a typed-OPEN LIST of items
  `[{"type": <key>, "value": <value>}]`.

  DATA migration only — the column stays a SCALAR `jsonb` (the new
  `Loopctl.Coordination.RefsList` custom `Ecto.Type` maps to `:map`/`jsonb`, now
  holding a top-level JSON array instead of an object). No column-type change.

  Idempotent / re-run-safe: only rows whose `refs` is a JSON OBJECT are reshaped;
  rows already an array, or NULL, or an empty `{}` are left untouched. Item order
  is STABLE (`ORDER BY key`, deterministic) so a `{file, pr}` map reshapes to
  `[{file}, {pr}]`.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE channel_posts
    SET refs = (
      SELECT jsonb_agg(
               jsonb_build_object('type', key, 'value', value)
               ORDER BY key
             )
      FROM jsonb_each_text(refs)
    )
    WHERE refs IS NOT NULL
      AND jsonb_typeof(refs) = 'object'
      AND refs <> '{}'::jsonb
    """)
  end

  def down do
    execute("""
    UPDATE channel_posts
    SET refs = (
      SELECT jsonb_object_agg(item ->> 'type', item ->> 'value')
      FROM jsonb_array_elements(refs) AS item
      WHERE item ? 'type' AND item ? 'value'
    )
    WHERE refs IS NOT NULL
      AND jsonb_typeof(refs) = 'array'
      AND jsonb_array_length(refs) > 0
    """)
  end
end
