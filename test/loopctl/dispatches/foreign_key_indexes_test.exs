defmodule Loopctl.Dispatches.ForeignKeyIndexesTest do
  @moduledoc """
  Every foreign key that references `dispatches` has a valid btree index whose leading KEY
  columns (INCLUDE columns do not count) are exactly the key's referencing columns, and
  which is either unconditional or conditioned only on one of those columns being NOT NULL,
  the one predicate every referential lookup on that key satisfies.

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
               FROM pg_index i
               JOIN pg_class ic ON ic.oid = i.indexrelid
               JOIN pg_am am ON am.oid = ic.relam,
                    LATERAL (SELECT (string_to_array(i.indkey::text, ' ')::int2[])
                              [1:least(i.indnkeyatts, array_length(c.conkey, 1))] AS lead) k
               WHERE i.indrelid = c.conrelid
                 AND i.indisvalid
                 AND am.amname = 'btree'
                 AND k.lead @> c.conkey AND k.lead <@ c.conkey
                 AND (i.indpred IS NULL
                      OR pg_get_expr(i.indpred, i.indrelid) IN (
                        SELECT '(' || quote_ident(a.attname) || ' IS NOT NULL)'
                        FROM pg_attribute a
                        WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
                      ))
             )
      FROM pg_constraint c
      WHERE c.confrelid = 'dispatches'::regclass AND c.contype = 'f'
      """)

    assert rows != [], "found no foreign keys into dispatches; the catalog query is wrong"

    unindexed = for [table, constraint, false] <- rows, do: "#{table} #{constraint}"
    assert unindexed == []
  end
end
