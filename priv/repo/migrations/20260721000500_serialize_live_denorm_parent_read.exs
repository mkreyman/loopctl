defmodule Loopctl.Repo.Migrations.SerializeLiveDenormParentRead do
  use Ecto.Migration

  @moduledoc """
  US-41.1 AC-41.1.1 (review) — close the `live_denorm` WRITE SKEW.

  `article_embeddings_set_live_denorm()` read the parent's status with a BARE
  `SELECT`, and the complementary propagation is an AFTER UPDATE trigger on the
  PARENT. Under READ COMMITTED those two do not serialize on an INSERT:

      TX1: INSERT article_embeddings   -- BEFORE trigger reads status='published'
                                       --   => live_denorm := true
      TX2: UPDATE articles SET status='superseded'
      TX2:   AFTER trigger: UPDATE article_embeddings ... WHERE article_id = NEW.id
             -- TX1's row is still UNCOMMITTED, so it is not seen: no-op
      both COMMIT                      -- the row stays live_denorm = true FOREVER

  The per-dimension HNSW indexes are PARTIAL on `live_denorm`, so the stale row is
  IN the index and occupies ANN pool slots on every recall — precisely the US-28.2
  regression AC-41.1.1 exists to make structurally impossible. Lock modes did not
  save it: the INSERT's FK check takes `FOR KEY SHARE` on `articles` and the status
  UPDATE takes `FOR NO KEY UPDATE`, which do not conflict.

  ## The fix: `FOR SHARE` on the parent read, INSERT-ONLY

  `FOR SHARE` DOES conflict with `FOR NO KEY UPDATE`, so the insert either takes the
  lock first (and TX2's propagation then sees the committed row and fixes it) or
  blocks until TX2 commits and reads the new status. Either interleaving converges.

  The lock is taken on INSERT ONLY, deliberately:

    * on INSERT the skew is real (the new row is invisible to the parent's
      propagation) and there is NO deadlock cycle — the propagating transaction can
      never block on a row it cannot see;
    * on UPDATE there is no skew (the row IS visible, so the parent's propagation
      blocks on it and applies the correct value afterwards) while locking WOULD
      introduce a cycle: side-row-lock-then-parent-lock against
      parent-lock-then-side-row-lock.

  The residual — a marker desynchronized by some path neither trigger covers — is
  swept by `Loopctl.Embeddings.article_live_denorm_drift/1` /
  `memory_live_denorm_drift/1`, which the reconciliation pass now repairs.
  """

  def up do
    execute(article_fn("FOR SHARE"))
    execute(memory_fn("FOR SHARE"))
  end

  def down do
    execute(article_fn(""))
    execute(memory_fn(""))
  end

  defp article_fn(lock) do
    """
    CREATE OR REPLACE FUNCTION article_embeddings_set_live_denorm() RETURNS trigger AS $$
    DECLARE
      parent_status text;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        SELECT a.status INTO parent_status FROM articles a WHERE a.id = NEW.article_id #{lock};
      ELSE
        SELECT a.status INTO parent_status FROM articles a WHERE a.id = NEW.article_id;
      END IF;

      NEW.live_denorm := COALESCE(parent_status, 'draft') <> 'superseded';
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp memory_fn(lock) do
    """
    CREATE OR REPLACE FUNCTION memory_embeddings_set_live_denorm() RETURNS trigger AS $$
    DECLARE
      parent_superseded_by uuid;
      parent_exists boolean;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        SELECT m.superseded_by, true INTO parent_superseded_by, parent_exists
        FROM memories m WHERE m.id = NEW.memory_id #{lock};
      ELSE
        SELECT m.superseded_by, true INTO parent_superseded_by, parent_exists
        FROM memories m WHERE m.id = NEW.memory_id;
      END IF;

      NEW.live_denorm := COALESCE(parent_exists, false) AND parent_superseded_by IS NULL;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
