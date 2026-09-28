defmodule Loopctl.WorkBreakdown.RestrictedDelete do
  @moduledoc """
  A delete that a non-cascading foreign key refuses answers a 422 changeset, never an
  `Ecto.ConstraintError` the fallback controller cannot render (loopctl #876, PR #924).

  A story or epic delete cascades through many tables, and ANY foreign key on that path that
  does not cascade — onto `stories` (dispatches, capability tokens, verification runs), onto
  `epics`, or onto a table the cascade reaches — makes Postgres refuse the whole delete. Naming
  each constraint on the changeset covers only the ones someone remembered; rescuing the
  refusal here covers every one, including those a later migration adds. A constraint a
  changeset DOES name (`intake_sources_target_epic_fkey` on the epic) still answers with its own
  message: Ecto converts it before anything raises.

  The change-thread ledger is not among these: it keys on a bare `story_id` with no foreign
  key so that it OUTLIVES the story (`20260926120000_create_thread_ledger.exs`).
  """

  @doc """
  Runs `fun` — the delete's transaction and the match on its result — and turns a foreign-key
  `Ecto.ConstraintError` into `{:error, changeset}` on `record`'s `:id`, naming the constraint.
  Every other exception still raises.
  """
  @spec run(struct(), (-> result)) :: result | {:error, Ecto.Changeset.t()} when result: term()
  def run(record, fun) do
    fun.()
  rescue
    error in Ecto.ConstraintError ->
      if error.type == :foreign_key do
        {:error,
         record
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:id, message(error.constraint), constraint: error.constraint)}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc "The refusal for a delete that `constraint` blocks."
  @spec message(String.t()) :: String.t()
  def message(constraint),
    do:
      "is still referenced through #{constraint}, which does not cascade: those records " <>
        "must go first, or this row stays"
end
