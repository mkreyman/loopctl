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
  #
  # ## The DEPLOY WINDOW, and why a trigger and not a DEFAULT (#846.4 review round 2, finding 5)
  #
  # `fly.toml` runs migrations as the `release_command` and then replaces machines one at a
  # time (`strategy = "rolling"`), so for the length of that roll the new column exists and
  # OLD instances are still serving. An old `enroll_runner` INSERT names no
  # `enrolled_max_sessions` — the column is not in its `Runner` schema — so a bare `NOT NULL`
  # with no server-side fallback 500s `POST /api/v1/runners` and the `runner_enroll` MCP tool
  # for that whole window.
  #
  # A column DEFAULT closes the window but gets the VALUE wrong: a Postgres column default
  # cannot reference another column, so the only constant available is 2 — and an operator
  # enrolling at 8 during the roll would be granted a permanent ceiling of 2, with no endpoint
  # that widens it in place. That is the operator's own number silently discarded.
  #
  # A BEFORE INSERT trigger CAN read the row, so it fills from `max_sessions` — exactly the
  # derivation `Loopctl.Runners.Runner.create_changeset/2` already makes
  # (`put_enrolled_max_sessions/1`). BEFORE ROW triggers run before NOT NULL is evaluated, so
  # the constraint stays. It is KEPT rather than dropped after the roll, because it is not a
  # deploy patch: it makes it impossible for ANY writer — a future one, a migration, a hand
  # INSERT — to create a runner whose ceiling is not the grant it was enrolled with. The
  # original "fail loudly rather than inherit a number nobody chose" rationale is satisfied,
  # because `max_sessions` is not a number nobody chose: it IS the operator's grant.
  #
  # It fires on INSERT only. Nothing may raise `enrolled_max_sessions` on a live row — that is
  # a security bound and wants its own change — and an UPDATE trigger filling it would be a
  # second way in.
  def up do
    alter table(:runners) do
      add :enrolled_max_sessions, :integer, null: true
    end

    execute "UPDATE runners SET enrolled_max_sessions = max_sessions"

    execute(
      """
      CREATE FUNCTION runners_default_enrolled_max_sessions() RETURNS trigger AS $$
      BEGIN
        IF NEW.enrolled_max_sessions IS NULL THEN
          NEW.enrolled_max_sessions := NEW.max_sessions;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION runners_default_enrolled_max_sessions()"
    )

    execute(
      """
      CREATE TRIGGER runners_default_enrolled_max_sessions
      BEFORE INSERT ON runners
      FOR EACH ROW EXECUTE FUNCTION runners_default_enrolled_max_sessions()
      """,
      "DROP TRIGGER runners_default_enrolled_max_sessions ON runners"
    )

    alter table(:runners) do
      modify :enrolled_max_sessions, :integer, null: false
    end

    create constraint(:runners, :runners_enrolled_max_sessions_range,
             check: "enrolled_max_sessions BETWEEN 1 AND 64"
           )
  end

  def down do
    drop constraint(:runners, :runners_enrolled_max_sessions_range)

    execute "DROP TRIGGER IF EXISTS runners_default_enrolled_max_sessions ON runners"
    execute "DROP FUNCTION IF EXISTS runners_default_enrolled_max_sessions()"

    alter table(:runners) do
      remove :enrolled_max_sessions
    end
  end
end
