defmodule Loopctl.Repo.Migrations.AddAuditLogKnowledgeLintIndex do
  use Ecto.Migration

  @moduledoc """
  Partial index over the nightly knowledge-lint completion events, so the `:consumer_stalled`
  dead-man's-switch (#765 item 6) can read them CROSS-TENANT without a sequential scan of
  `audit_log`. `detect_consumer_stalled_scan/1` reads the last N `knowledge.lint_completed` rows PER
  TENANT, which no index serves; its predicate is `entity_type` alone, not `(entity_type, action)`.

  ## Locking

  `CREATE INDEX CONCURRENTLY` is not supported on a partitioned PARENT but IS supported per
  PARTITION, so the parent index is created `ON ONLY` (catalog-only) and each partition's is then
  built CONCURRENTLY and ATTACHed. Building it on the parent instead holds a lock per partition for
  the whole build, blocking audit writes — and so every mutating API request — for a time that grows
  with the retained corpus; here only the brief ATTACH blocks. A build that dies midway leaves an
  INVALID index behind, so the probe below asks for a VALID index ATTACHED to the parent rather than
  for one of the right NAME — matching by name alone let a re-run skip the orphan, never attach it,
  and exit 0 with the parent index unusable. Any such orphan is dropped and rebuilt.
  Future partitions inherit it (`AuditPartitionWorker` uses `CREATE TABLE ... PARTITION OF`), and
  `down` drops the parent index with every attached partition index.
  """

  # CONCURRENTLY cannot run in a transaction; the migration lock goes with it.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "audit_log_knowledge_lint_idx"
  @shape "(tenant_id, inserted_at DESC) WHERE entity_type = 'knowledge_lint'"

  def up do
    execute("CREATE INDEX IF NOT EXISTS #{@index} ON ONLY audit_log #{@shape}")

    for partition <- partitions_without_valid_index() do
      child = "#{partition}_knowledge_lint_idx"
      # Only an unattached or INVALID leftover can be named here, so dropping it is the
      # repair: attaching an invalid child marks the parent invalid for good.
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{child}")
      execute("CREATE INDEX CONCURRENTLY #{child} ON #{partition} #{@shape}")
      execute("ALTER INDEX #{@index} ATTACH PARTITION #{child}")
    end
  end

  def down, do: execute("DROP INDEX IF EXISTS #{@index}")

  defp partitions_without_valid_index do
    %{rows: rows} =
      repo().query!(
        "SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid " <>
          "JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = 'audit_log' AND NOT " <>
          "EXISTS (SELECT 1 FROM pg_class x JOIN pg_index ix ON ix.indexrelid = x.oid " <>
          "JOIN pg_inherits xi ON xi.inhrelid = x.oid JOIN pg_class xp ON xp.oid = " <>
          "xi.inhparent WHERE x.relname = c.relname || '_knowledge_lint_idx' AND " <>
          "ix.indisvalid AND xp.relname = '#{@index}') ORDER BY c.relname"
      )

    Enum.map(rows, fn [name] -> name end)
  end
end
