defmodule Loopctl.WorkBreakdown.RestrictedDelete do
  @moduledoc """
  The DELETE step of a story or epic delete, answering what a caller can act on instead of
  raising (loopctl #876, PR #924):

  - `{:ok, deleted}` when the row is gone;
  - `{:error, :not_found}` when it was ALREADY gone (a racing delete, or a story its epic's
    cascade took) — a 404, not a refusal;
  - `{:error, changeset}` when a foreign key that does not cascade refuses the delete. A story
    or epic delete cascades through many tables, and any non-cascading reference on that path
    — onto `stories` (dispatches, capability tokens, verification runs are kept on purpose),
    onto `epics`, or onto a table the cascade reaches, including one a later migration adds —
    makes Postgres refuse it. Rescuing the refusal covers every one; naming each constraint
    covered only the ones someone remembered. A constraint the changeset DOES name
    (`intake_sources_target_epic_fkey` on the epic) keeps its own message.

  Only the delete statement is inside the rescue: it runs as the transaction's own step, so a
  foreign-key failure anywhere else in that transaction (the audit insert) still raises and is
  not reported as a reference on the row. The change-thread ledger is not a reference at all:
  it keys on a bare `story_id` with no foreign key so that it OUTLIVES the story
  (`20260926120000_create_thread_ledger.exs`).
  """

  @doc """
  Deletes `changeset` (or a struct) on `repo` inside the caller's transaction, as a
  `Ecto.Multi.run/3` step. `subject` words the refusal: `:story` or `:epic`.
  """
  @spec delete(module(), Ecto.Changeset.t() | struct(), :story | :epic) ::
          {:ok, struct()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete(repo, changeset_or_struct, subject) do
    changeset = Ecto.Changeset.change(changeset_or_struct)

    case repo.delete(changeset, stale_error_field: :id) do
      {:ok, deleted} -> {:ok, deleted}
      {:error, %Ecto.Changeset{} = refused} -> not_found_or(refused)
    end
  rescue
    error in Ecto.ConstraintError ->
      if error.type == :foreign_key do
        {:error,
         changeset_or_struct
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:id, message(subject))}
      else
        reraise error, __STACKTRACE__
      end
  end

  # `stale_error_field` marks a row the DELETE found missing with `stale: true`.
  defp not_found_or(%Ecto.Changeset{errors: errors} = changeset) do
    if Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:stale] end),
      do: {:error, :not_found},
      else: {:error, changeset}
  end

  @doc """
  The refusal. It names no constraint (that is schema detail) and promises no remedy: the
  records that refuse a delete are delivery history kept on purpose, with no route that
  removes them, so such a story, and an epic holding one, is not deletable.
  """
  @spec message(:story | :epic) :: String.t()
  def message(:story),
    do:
      "is referenced by records that are kept on purpose (such as its dispatches, capability " <>
        "tokens or verification runs), so it cannot be deleted"

  def message(:epic),
    do:
      "has a story referenced by records that are kept on purpose (such as dispatches, " <>
        "capability tokens or verification runs), so it cannot be deleted"
end
