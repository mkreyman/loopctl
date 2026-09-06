defmodule Loopctl.Repo.Migrations.AddRetrievalSuppressionToArticles do
  @moduledoc """
  A REVERSIBLE retrieval tombstone for an article: it stops being retrieved, it keeps
  being readable by id, and putting it back is one call.

  ## Why a new marker rather than an existing status

  `:archived` is TERMINAL (#605/#606) and `unpublish` claims the article is a DRAFT, which is
  an editorial statement rather than a retrieval one — so neither says what an unattended
  writer needs to say. Suppression says nothing about status and everything about retrieval:
  the article keeps its status, embedding, links and body, leaves every ranked surface, and
  stays resolvable by id so the act is inspectable and undoable. Full reasoning, and the
  read paths it binds, live in `Loopctl.Knowledge.Suppression`.

  ## The three columns

    * `suppressed_at` — the tombstone. `NULL` means retrievable; this is the ONLY predicate
      any read path checks, so the other two can never change what is returned.
    * `suppressed_by` — a bounded ACTOR LABEL (varchar 200), the same
      `actor_label` shape the audit log records. Who did it.
    * `suppression_reason` — bounded free text (varchar 500). Why.

  Bounded at the COLUMN, not only in the changeset: these are written by an agent-role
  endpoint, and an unbounded `text` reason on a hot table is a write amplifier a caller
  controls. 500 matches `Loopctl.Knowledge.KbCuration`'s `@max_summary`, since the same
  sentence lands in both places.

  **Never add any of the three to a changeset `cast` list.** They are written programmatically
  by `Loopctl.Knowledge.Article.suppression_changeset/2`, reached only through
  `Loopctl.Knowledge.suppress_article/3` and `unsuppress_article/2`. `metadata` is cast and
  whole-map-REPLACED by `PATCH /api/v1/knowledge/:id`, so recording a tombstone there would
  let one ordinary request un-suppress an article with no audit event and no actor — the
  `stories.lifecycle_entered_at` lesson (CLAUDE.md) reached by a third subsystem, after
  `previous_title` (#765) and `staged_draft_at`.

  ## RLS

  Nothing to do. `articles` already has row-level security enabled with its per-tenant
  policy; adding columns to an existing table does not change the policy, and the policy is
  on the ROW, so the new columns inherit it. The `tenancy-rls` skill's `ENABLE ROW LEVEL
  SECURITY` rule applies to NEW tables only. Checked, not assumed.

  ## The index

  Partial, on `(tenant_id, suppressed_at) WHERE suppressed_at IS NOT NULL`. It serves the
  ONE query shape that looks FOR suppressed rows — the `suppressed=only` listing an operator
  uses to find something to undo — and it is tiny, because the suppressed set is a small
  fraction of the corpus by construction. It deliberately does NOT try to serve the far
  commoner `IS NULL` half: that predicate matches nearly every row, so an index on it would
  be corpus-sized and no planner would choose it over the existing scans.

  Built CONCURRENTLY, the convention 20260827121000 set for this exact table: a plain
  `CREATE INDEX` SHARE-locks `articles` and blocks every write for the build. That costs the
  two `@disable_*` attributes, so the ALTER and the CREATE are separate transactions and both
  are written convergently — and `IF NOT EXISTS` alone is not enough, since an interrupted
  concurrent build leaves an INVALID index that satisfies it, which is what `stale?/0` drops.

  All three columns are nullable with no default, so the ALTER is catalog-only on PG11+ —
  no table rewrite on a corpus of ~86k articles.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "articles_tenant_suppressed_idx"

  @create "CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_tenant_suppressed_idx " <>
            "ON articles (tenant_id, suppressed_at) WHERE suppressed_at IS NOT NULL"

  def up do
    alter table(:articles) do
      add_if_not_exists :suppressed_at, :utc_datetime_usec
      add_if_not_exists :suppressed_by, :string, size: 200
      add_if_not_exists :suppression_reason, :string, size: 500
    end

    if stale?(), do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")
    execute(@create)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")

    alter table(:articles) do
      remove_if_exists :suppression_reason, :string
      remove_if_exists :suppressed_by, :string
      remove_if_exists :suppressed_at, :utc_datetime_usec
    end
  end

  # Stale = INVALID or ambiguous. Absent is NOT stale: the CREATE lays it down.
  @stale_sql "SELECT x.indisvalid FROM pg_class c JOIN pg_index x ON x.indexrelid = c.oid " <>
               "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = $1 " <>
               "AND c.relkind = 'i' AND n.nspname = 'public'"

  defp stale? do
    case repo().query!(@stale_sql, [@name]).rows do
      [[true]] -> false
      rows -> rows != []
    end
  end
end
