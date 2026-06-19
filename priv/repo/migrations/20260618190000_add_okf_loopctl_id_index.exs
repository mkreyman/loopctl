defmodule Loopctl.Repo.Migrations.AddOkfLoopctlIdIndex do
  use Ecto.Migration

  # OKF import resolves a re-imported article by the producer key stashed in
  # `metadata->'okf'->>'loopctl_id'`. Without an index that lookup is a sequential
  # scan per concept (O(n²) for a full-bundle re-import). A partial expression
  # index keyed by (tenant_id, loopctl_id) makes it a point lookup and stays tiny
  # (only rows that were imported from an OKF bundle carry the key).
  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS articles_okf_loopctl_id_idx
    ON articles (tenant_id, (metadata->'okf'->>'loopctl_id'))
    WHERE metadata->'okf'->>'loopctl_id' IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS articles_okf_loopctl_id_idx")
  end
end
