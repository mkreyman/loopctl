defmodule Loopctl.Dispatches.ForeignKeyIndexesTest do
  @moduledoc """
  Every foreign key that references `dispatches` has an index led by its referencing column.

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
      SELECT c.conrelid::regclass::text, a.attname,
             EXISTS (
               SELECT 1 FROM pg_index i
               WHERE i.indrelid = c.conrelid AND i.indisvalid AND i.indkey[0] = c.conkey[1]
             )
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.confrelid = 'dispatches'::regclass AND c.contype = 'f'
      """)

    assert rows != [], "found no foreign keys into dispatches; the catalog query is wrong"

    unindexed = for [table, column, false] <- rows, do: "#{table}.#{column}"
    assert unindexed == []
  end
end
