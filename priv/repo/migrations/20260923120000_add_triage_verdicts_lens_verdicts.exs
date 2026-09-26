defmodule Loopctl.Repo.Migrations.AddTriageVerdictsLensVerdicts do
  @moduledoc """
  The three triage lenses' own judgements, beside the merged verdict (epic 44, US-44.1;
  runner contract 1.15.0). No backfill and no manual step: the column starts NULL for every
  existing row, which Gate A reads as "no lens verdicts" and refuses rather than passes.

  An OBJECT keyed by lens name (`analyst`, `architect`, `engineer`) rather than an array, so
  "each lens exactly once" is a property of the stored shape and a plain `:map` field reads
  it. The CHECK holds the shape at the database, where a writer that bypassed the cast would
  otherwise store an array Gate A cannot read.
  """

  use Ecto.Migration

  def up do
    alter table(:triage_verdicts) do
      add :lens_verdicts, :map
    end

    execute("""
    ALTER TABLE triage_verdicts
      ADD CONSTRAINT triage_verdicts_lens_verdicts_shape
      CHECK (lens_verdicts IS NULL OR jsonb_typeof(lens_verdicts) = 'object')
    """)
  end

  def down do
    execute("ALTER TABLE triage_verdicts DROP CONSTRAINT triage_verdicts_lens_verdicts_shape")

    alter table(:triage_verdicts) do
      remove :lens_verdicts
    end
  end
end
