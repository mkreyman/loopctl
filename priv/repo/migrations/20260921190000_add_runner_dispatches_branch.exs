defmodule Loopctl.Repo.Migrations.AddRunnerDispatchesBranch do
  use Ecto.Migration

  # THE BRANCH A DISPATCH WAS SENT ON, so a RETRY of that dispatch cannot land on a different
  # one (#846.2 review round 2, finding 4).
  #
  # Before contract 1.14.0 the branch was a pure function of the story, so every push under one
  # `dispatch_id` named the same string and the ledger had nothing to remember. The branch now
  # also depends on what the TARGET RUNNER declared on its current connection, which a rejoin
  # changes — so a resume re-derived, and could re-derive a DIFFERENT name.
  #
  # The comment that shipped with that change argued it was safe because a resume only runs
  # against a row still at `sent`, "so the first frame was never accepted and no session
  # started". That overstates what `sent` means: it means no reply was RECORDED, and a LOST
  # REPLY is exactly the case a resume exists for. So a session may be running on the first
  # branch while the retry pushes a second name under the same `dispatch_id`.
  #
  # Nullable with NO backfill and no trigger, deliberately. A row written before this migration
  # genuinely does not know its branch, and inventing one by re-deriving it now would record a
  # guess as a fact; `Loopctl.Delivery.Placement` falls back to deriving for exactly those rows
  # and says so. Nothing reads the column for an authorization or capacity decision, so a NULL
  # costs a resume its pin and nothing else.
  #
  # NO DEPLOY WINDOW to close. `fly.toml` runs migrations as the release_command and then rolls
  # machines one at a time, so old instances serve while this column exists — and an old
  # `record_sent/3` INSERT that names no `branch` is accepted, because the column is nullable.
  def change do
    alter table(:runner_dispatches) do
      add :branch, :string, null: true
    end
  end
end
