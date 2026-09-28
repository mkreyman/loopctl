defmodule Loopctl.Dispatches.ForeignKeyIndexesTest do
  @moduledoc """
  Every foreign key that references `dispatches` has a valid index whose leading columns are
  exactly the key's referencing columns, and which is either unconditional or conditioned
  only on a column being NOT NULL, the one predicate every referential lookup satisfies.

  Deleting a dispatch runs one referential check per deleted row against each referencing
  table; without that index each check scans the table, so a bulk delete of N dispatches
  costs N scans. 20260928140000_index_foreign_keys_into_dispatches added the two that were
  missing. This reads the catalog, so a new foreign key into `dispatches` without its index
  fails here rather than in the first bulk delete that meets it.
  """

  use Loopctl.DataCase, async: true

  test "every foreign key referencing dispatches is indexed on its referencing column" do
    %{rows: rows} =
      Loopctl.AdminRepo.query!("""
      SELECT c.conrelid::regclass::text, c.conname,
             EXISTS (
               SELECT 1
               FROM pg_index i,
                    LATERAL (SELECT (string_to_array(i.indkey::text, ' ')::int2[])
                              [1:array_length(c.conkey, 1)] AS lead) k
               WHERE i.indrelid = c.conrelid
                 AND i.indisvalid
                 AND k.lead @> c.conkey AND k.lead <@ c.conkey
                 AND (i.indpred IS NULL
                      OR pg_get_expr(i.indpred, i.indrelid) ~ '^\\(\\w+ IS NOT NULL\\)$')
             )
      FROM pg_constraint c
      WHERE c.confrelid = 'dispatches'::regclass AND c.contype = 'f'
      """)

    assert rows != [], "found no foreign keys into dispatches; the catalog query is wrong"

    unindexed = for [table, constraint, false] <- rows, do: "#{table} #{constraint}"
    assert unindexed == []
  end
end
