defmodule Loopctl.Repo.Migrations.AddRunnerEnrolledMaxSessions do
  use Ecto.Migration

  # THE ENROLLMENT GRANT, KEPT (#846.4 review finding 2). `runners.max_sessions` became the
  # number the MACHINE declares on every join, which is right — the machine owns the fact. But
  # it was written OVER the enrolled number, so nothing remembered what the operator had
  # granted, and a runner could raise its own share of the tenant's admission budget by
  # declaring a larger one: a compromised or misconfigured machine declaring 64 absorbs the
  # tenant's slots, and every dispatch it then wins carries story content and a freshly minted
  # ephemeral key. Before that change it could not enlarge its own share at all.
  #
  # So the enrolled value stays in a column of its own and becomes a CEILING: a join writes
  # `max_sessions = LEAST(declared, enrolled_max_sessions)`. A machine may always lower itself
  # and never raise itself, which is the direction the asymmetry already argued for — holding
  # more than the machine can run over-reserves and parks stories, holding less only
  # under-uses it.
  #
  # Backfilled from `max_sessions`, which on every existing row IS the enrolled value: this
  # migration ships with the change that first writes a declaration into that column, so no
  # row has been overwritten yet.
  def up do
    alter table(:runners) do
      add :enrolled_max_sessions, :integer, null: true
    end

    execute "UPDATE runners SET enrolled_max_sessions = max_sessions"

    alter table(:runners) do
      modify :enrolled_max_sessions, :integer, null: false
    end

    create constraint(:runners, :runners_enrolled_max_sessions_range,
             check: "enrolled_max_sessions BETWEEN 1 AND 64"
           )
  end

  def down do
    drop constraint(:runners, :runners_enrolled_max_sessions_range)

    alter table(:runners) do
      remove :enrolled_max_sessions
    end
  end
end
