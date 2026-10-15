defmodule Loopctl.Repo.Migrations.AddThreadEntryKbRefs do
  @moduledoc """
  #978: `thread_entries.kb_refs`, the knowledge articles a `message` or `checkpoint` entry
  acted on, so a review reads which KB decision each checkpoint relied on as data instead of
  scraping ids out of a body.

  Ids only, never article bodies: the thread stays a ledger of what a session wrote on
  purpose (Epic 45 PRD §6.2). `Loopctl.Threads` validates each id against the articles the
  writing key can see before the entry is written, and the bound is
  `Loopctl.Threads.Entry.max_kb_refs/0`; the CHECKs below restate both shape rules so a write
  that bypasses the context cannot store a reference list on a judgement or an unbounded one.

  `NOT NULL DEFAULT '{}'`: a constant default is a catalog-only change on PostgreSQL 11+, so
  the column lands without rewriting the table, and every existing entry reads as citing
  nothing, which is what it did.
  """

  use Ecto.Migration

  # Restated from `Loopctl.Threads.Entry.max_kb_refs/0`: a migration must not call application
  # code, whose value may move after this file has run.
  @max_kb_refs 20

  def change do
    alter table(:thread_entries) do
      add :kb_refs, {:array, :binary_id}, null: false, default: fragment("'{}'::uuid[]")
    end

    create constraint(:thread_entries, :thread_entries_kb_refs_bound,
             check: "cardinality(kb_refs) <= #{@max_kb_refs}"
           )

    create constraint(:thread_entries, :thread_entries_kb_refs_kinds,
             check: "cardinality(kb_refs) = 0 OR kind IN ('message', 'checkpoint')"
           )
  end
end
