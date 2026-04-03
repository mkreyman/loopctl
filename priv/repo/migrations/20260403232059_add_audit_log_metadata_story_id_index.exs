defmodule Loopctl.Repo.Migrations.AddAuditLogMetadataStoryIdIndex do
  use Ecto.Migration

  def up do
    # Btree index on the extracted story_id from the audit_log metadata JSONB
    # column. Supports efficient story history queries that include
    # token_usage_report entries via metadata->>'story_id' (AC-21.8.6).
    # Note: Cannot use CONCURRENTLY on partitioned tables.
    execute """
    CREATE INDEX IF NOT EXISTS audit_log_metadata_story_id_idx
      ON audit_log ((metadata->>'story_id'))
      WHERE metadata->>'story_id' IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS audit_log_metadata_story_id_idx"
  end
end
