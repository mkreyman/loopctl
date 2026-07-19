defmodule Loopctl.Repo.Migrations.ReshapeChannelPostsRefsToList do
  @moduledoc """
  US-40.A1: reshape `channel_posts.refs` from a fixed-key MAP
  (`{file,pr,branch,commit}`) to a typed-OPEN LIST of items
  `[{"type": <key>, "value": <value>}]`.

  DATA migration only — the column stays a SCALAR `jsonb` (the new
  `Loopctl.Coordination.RefsList` custom `Ecto.Type` maps to `:map`/`jsonb`, now
  holding a top-level JSON array instead of an object). No column-type change.

  Idempotent / re-run-safe: EVERY row whose `refs` is a JSON OBJECT is reshaped —
  including an empty `{}`, which becomes an empty LIST `[]` (via `COALESCE(..,
  '[]')`, since `jsonb_agg` over zero pairs is NULL). Skipping `{}` would leave a
  live row the `RefsList` custom type cannot load (`load/1` accepts only a list or
  nil and would raise on a map), 500-ing the whole channel read — so every object
  row MUST be normalised, not just the non-empty ones (AC-40.A1.5: no live row
  breaks). Rows already an array, or NULL, are left untouched. Item order is STABLE
  (`ORDER BY key`, deterministic) so a `{file, pr}` map reshapes to `[{file}, {pr}]`.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE channel_posts
    SET refs = COALESCE(
      (
        SELECT jsonb_agg(
                 jsonb_build_object('type', key, 'value', value)
                 ORDER BY key
               )
        FROM jsonb_each_text(refs)
      ),
      '[]'::jsonb
    )
    WHERE refs IS NOT NULL
      AND jsonb_typeof(refs) = 'object'
    """)
  end

  def down do
    execute("""
    UPDATE channel_posts
    SET refs = COALESCE(
      (
        SELECT jsonb_object_agg(item ->> 'type', item ->> 'value')
        FROM jsonb_array_elements(refs) AS item
        WHERE item ? 'type' AND item ? 'value'
      ),
      '{}'::jsonb
    )
    WHERE refs IS NOT NULL
      AND jsonb_typeof(refs) = 'array'
    """)
  end
end
