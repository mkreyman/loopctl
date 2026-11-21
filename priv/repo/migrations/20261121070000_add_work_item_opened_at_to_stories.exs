defmodule Loopctl.Repo.Migrations.AddWorkItemOpenedAtToStories do
  @moduledoc """
  A story opened as an interactive work item (US-52.18) says so, and implement@1 never places
  one.

  When a holder ends, its uncapped claims are released through `unclaim`, which moves the
  item's stage back to `queued` so the session that re-registers can take its branch's item
  back. implement@1 read every `queued` authored story as a candidate, so the factory placed
  the session's own branch on a runner: in production on 2026-11-21 five items were claimed
  and dispatched, and each placed session refused or escalated a story with no description
  and no acceptance criteria.

  `stories.work_item_opened_at` is stamped by `Loopctl.WorkItems.Open` when it CREATES the
  item and never cast (`metadata` is whole-map-replaced by a PATCH, so a marker there could be
  erased by one request). `Loopctl.Agents.Candidates`' `:not_work_item` reads it.

  The backfill reads the `work_item_opened` audit entry, which only the create path writes. The
  item event log is not a usable source: a take-back of an existing story writes the same
  `claimed` reason as a create, and runtime stamps only a create. `audit_log` FORCES row level
  security, whose policy checks `current_tenant_id()` and holds the table owner too, so the
  backfill sets the tenant GUC per tenant, transaction-locally.
  """

  use Ecto.Migration

  def up do
    alter table(:stories) do
      add :work_item_opened_at, :utc_datetime_usec
    end

    execute(backfill_sql())
  end

  @doc "The backfill `up/0` runs; public so the test drives the same SQL."
  def backfill_sql do
    """
    DO $$
    DECLARE
      t uuid;
    BEGIN
      FOR t IN SELECT id FROM tenants LOOP
        PERFORM set_config('app.current_tenant_id', t::text, true);

        UPDATE stories s
           SET work_item_opened_at = a.opened_at
          FROM (
            SELECT entity_id, min(inserted_at) AS opened_at
              FROM audit_log
             WHERE tenant_id = t AND entity_type = 'story' AND action = 'work_item_opened'
             GROUP BY entity_id
          ) a
         WHERE s.tenant_id = t AND s.id = a.entity_id;
      END LOOP;

      PERFORM set_config('app.current_tenant_id', '', true);
    END
    $$;
    """
  end

  def down do
    alter table(:stories) do
      remove :work_item_opened_at
    end
  end
end
