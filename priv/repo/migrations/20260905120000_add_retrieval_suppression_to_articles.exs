defmodule Loopctl.Repo.Migrations.AddRetrievalSuppressionToArticles do
  @moduledoc """
  A REVERSIBLE retrieval tombstone for an article: it stops being retrieved, it keeps
  being readable by id, and putting it back is one call.

  ## Why a new marker rather than an existing status

  `:archived` is TERMINAL — `Loopctl.Knowledge.Article`'s `@valid_transitions` carries no
  `{:archived, _}` entry and there is no unarchive function, so the only way back is a
  `user+` PATCH with an explicit status (#605/#606). Nothing is destroyed and the act is
  audited, which is what earns it agent role; nothing AUTOMATED restores it, which is a
  different property and the one an unattended writer depends on. That is why the nightly
  consolidation pass had to reach for `unpublish` as a stand-in when it retracts a confirmed
  duplicate (#608) — `unpublish` is undoable, but it means "this is a draft", which is a
  claim about the article's editorial state rather than about its retrievability.

  Suppression is the missing primitive: it says nothing about status and everything about
  retrieval. A suppressed article keeps its status, its embedding, its links and its body;
  it is excluded from every ranked/retrieval surface and stays resolvable by id so the
  suppression is inspectable and undoable.

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

  All three columns are nullable with no default, so the ALTER is catalog-only on PG11+ —
  no table rewrite on a corpus of ~86k articles.
  """

  use Ecto.Migration

  def up do
    alter table(:articles) do
      add :suppressed_at, :utc_datetime_usec
      add :suppressed_by, :string, size: 200
      add :suppression_reason, :string, size: 500
    end

    create index(:articles, [:tenant_id, :suppressed_at],
             where: "suppressed_at IS NOT NULL",
             name: :articles_tenant_suppressed_idx
           )
  end

  def down do
    drop index(:articles, [:tenant_id, :suppressed_at], name: :articles_tenant_suppressed_idx)

    alter table(:articles) do
      remove :suppression_reason
      remove :suppressed_by
      remove :suppressed_at
    end
  end
end
