defmodule Loopctl.Repo.Migrations.AddThreadEntryKbRefs do
  @moduledoc """
  #978: `thread_entries.kb_refs`, the knowledge articles a `message` or `checkpoint` entry
  acted on, so a review reads which KB decision each checkpoint relied on as data instead of
  scraping ids out of a body.

  Ids only, never article bodies: the thread stays a ledger of what a session wrote on
  purpose (Epic 45 PRD §6.2). `Loopctl.Threads` validates each id against the articles the
  writing key can read before the entry is written, and the bound is
  `Loopctl.Threads.Entry.max_kb_refs/0`; the CHECKs below restate both shape rules so a write
  that bypasses the context cannot store a reference list on a judgement or an unbounded one.

  `NOT NULL DEFAULT '{}'`: a constant default is a catalog-only change on PostgreSQL 11+, so
  the column lands without rewriting the table, and every existing entry reads as citing
  nothing, which is what it did.

  Online-safe locking, as `20260723120000_add_hash_version_check_to_audit_chain`: with the
  DDL transaction disabled each statement commits on its own, so the ACCESS EXCLUSIVE lock
  the ADDs take is released at once (both are catalog-only: the column by its constant
  default, each CHECK by `NOT VALID`), and the VALIDATE scans that follow hold only SHARE
  UPDATE EXCLUSIVE, under which every runner checkpoint and thread entry keeps writing.
  Inside one transaction the scan would run under the ADD's lock and block them all.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Restated from `Loopctl.Threads.Entry.max_kb_refs/0`: a migration must not call application
  # code, whose value may move after this file has run.
  @max_kb_refs 20

  def up do
    execute(
      "ALTER TABLE thread_entries ADD COLUMN IF NOT EXISTS kb_refs uuid[] NOT NULL DEFAULT '{}'"
    )

    execute(
      "ALTER TABLE thread_entries ADD CONSTRAINT thread_entries_kb_refs_bound " <>
        "CHECK (cardinality(kb_refs) <= #{@max_kb_refs}) NOT VALID"
    )

    execute(
      "ALTER TABLE thread_entries ADD CONSTRAINT thread_entries_kb_refs_kinds " <>
        "CHECK (cardinality(kb_refs) = 0 OR kind IN ('message', 'checkpoint')) NOT VALID"
    )

    execute("ALTER TABLE thread_entries VALIDATE CONSTRAINT thread_entries_kb_refs_bound")
    execute("ALTER TABLE thread_entries VALIDATE CONSTRAINT thread_entries_kb_refs_kinds")
  end

  def down do
    execute("ALTER TABLE thread_entries DROP CONSTRAINT IF EXISTS thread_entries_kb_refs_kinds")
    execute("ALTER TABLE thread_entries DROP CONSTRAINT IF EXISTS thread_entries_kb_refs_bound")
    execute("ALTER TABLE thread_entries DROP COLUMN IF EXISTS kb_refs")
  end
end
