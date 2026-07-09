defmodule Loopctl.Repo.MemoryStoresMigrationTest do
  @moduledoc """
  US-28.1 / TC-28.1.1 — asserts the two memory-store tables exist on a
  migrated DB with the AC columns, the (tenant_id, subject_id) btree on
  `memories`, and an HNSW index on `memories.embedding`.

  The HNSW index is detected BY CAPABILITY (`pg_am.amname = 'hnsw'`), never by a
  hard-coded name — tolerating prod name drift (AC-28.1.3). Column/index presence
  is asserted directly against the real tables (mirroring
  `Loopctl.KnowledgeEmbeddingTest`'s canonical-index assertion on `articles`);
  no throwaway table is needed since these are read-only catalog queries.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo

  defp columns(table) do
    AdminRepo.query!(
      "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1",
      [table]
    ).rows
    |> Map.new(fn [name, type] -> {name, type} end)
  end

  # pg_constraint.confdeltype for the FK on `table.column`: "n" = SET NULL
  # (nilify_all), "c" = CASCADE (delete_all), "a" = NO ACTION, "r" = RESTRICT.
  defp fk_on_delete(table, column) do
    %{rows: [[confdeltype]]} =
      AdminRepo.query!(
        """
        SELECT c.confdeltype
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f' AND n.nspname = 'public'
          AND t.relname = $1 AND a.attname = $2
        """,
        [table, column]
      )

    confdeltype
  end

  describe "session_memories table" do
    test "has all AC-28.1.1 columns" do
      cols = columns("session_memories")

      for name <-
            ~w(id tenant_id project_id session_id subject_id role content metadata expires_at inserted_at) do
        assert Map.has_key?(cols, name), "session_memories missing column #{name}"
      end

      # Append-only: no updated_at column.
      refute Map.has_key?(cols, "updated_at")
      assert cols["expires_at"] == "timestamp without time zone"
      assert cols["metadata"] == "jsonb"
    end

    test "has the (tenant_id, session_id, inserted_at) and expires_at indexes" do
      assert index_columns("session_memories", ["tenant_id", "session_id", "inserted_at"])
      assert index_columns("session_memories", ["expires_at"])
    end
  end

  describe "memories table" do
    test "has all AC-28.1.2 columns" do
      cols = columns("memories")

      for name <-
            ~w(id tenant_id project_id subject_id text embedding embedding_content_hash confidence source source_session_id tags superseded_by inserted_at updated_at) do
        assert Map.has_key?(cols, name), "memories missing column #{name}"
      end

      assert cols["confidence"] == "double precision"
      assert cols["tags"] == "ARRAY"
    end

    test "has the (tenant_id, subject_id) btree index" do
      assert index_columns("memories", ["tenant_id", "subject_id"])
    end

    # A long-term memory is durable: deleting its project must fall it back to
    # tenant-wide scope (project_id = NULL), NOT destroy the memory. session
    # memories expire anyway, so they keep cascade delete.
    test "project_id FK is ON DELETE SET NULL (nilify_all), not cascade" do
      assert fk_on_delete("memories", "project_id") == "n"
      assert fk_on_delete("session_memories", "project_id") == "c"
    end

    # AC-28.1.3 / TC-28.1.1: detect the HNSW index by access method, not by name.
    test "has an HNSW index on embedding (detected by amname, not name)" do
      %{rows: rows} =
        AdminRepo.query!(
          """
          SELECT i.relname
          FROM pg_index x
          JOIN pg_class i ON i.oid = x.indexrelid
          JOIN pg_class t ON t.oid = x.indrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          JOIN pg_am am ON am.oid = i.relam
          WHERE t.relname = 'memories' AND n.nspname = 'public' AND am.amname = 'hnsw'
          """,
          []
        )

      assert length(rows) == 1,
             "expected exactly one hnsw index on memories, got #{inspect(rows)}"
    end
  end

  # True if an index on `table` covers exactly `cols` (in order), via pg_indexes indexdef.
  defp index_columns(table, cols) do
    %{rows: rows} =
      AdminRepo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1",
        [table]
      )

    expected = "(" <> Enum.join(cols, ", ") <> ")"

    Enum.any?(rows, fn [indexdef] -> String.contains?(indexdef, expected) end)
  end
end
