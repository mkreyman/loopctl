defmodule Loopctl.WorkBreakdown.StoryLifecycleReferencesTest do
  @moduledoc """
  Binds `Story.lifecycle_references/0` to the database (loopctl #923): every foreign key onto
  `stories` that does NOT cascade or nullify must be named there, or deleting a story or an
  epic that holds such a row raises an `Ecto.ConstraintError` no fallback can render — a 500.
  A new custody table with `on_delete: :nothing` fails this test until it is named.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Story

  test "every non-cascading foreign key onto stories is named" do
    %{rows: rows} =
      AdminRepo.query!("""
      SELECT conname FROM pg_constraint
      WHERE contype = 'f'
        AND confrelid = 'stories'::regclass
        AND confdeltype NOT IN ('c', 'n', 'd')
      ORDER BY conname
      """)

    in_database = rows |> List.flatten() |> Enum.map(&String.to_existing_atom/1)

    assert in_database != []
    assert Enum.sort(in_database) == Enum.sort(Story.lifecycle_references())
  end
end
