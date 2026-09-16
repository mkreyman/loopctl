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
  # the constraint stays. The original "fail loudly rather than inherit a number nobody chose"
  # rationale is satisfied, because `max_sessions` is not a number nobody chose: it IS the
  # operator's grant. It is KEPT rather than dropped after the roll, so that a later writer
  # which omits the column gets the same fill instead of a NOT NULL violation.
  #
  # ## WHAT IT ENFORCES, WHICH IS LESS THAN THIS COMMENT ONCE CLAIMED
  # (#846.4 review round 3, finding 3)
  #
  # It fills an OMITTED value. It does not constrain a SUPPLIED one — `IF NEW.enrolled_max_sessions
  # IS NULL` is the whole body — so an INSERT naming `max_sessions: 1,
  # enrolled_max_sessions: 64`
  # is accepted exactly as written. `test/loopctl/runners_test.exs` pins that behaviour ("a writer
  # that DOES name it keeps its own value"); this comment claimed the opposite in the same commit.
  #
  # Making the assignment unconditional would make the stronger claim true for INSERT and would
  # buy nothing, because the widening this column exists to prevent does not arrive by INSERT. The
  # principal it bounds is a CONNECTED RUNNER, which reaches this row only through
  # `Loopctl.Runners.Capacity.apply_declared/5`, and that reads `enrolled_max_sessions` and never
  # writes it; `create_changeset/2` derives it and does not cast it. A principal that can INSERT
  # into `runners` by hand can equally `UPDATE runners SET enrolled_max_sessions = 64`, which no
  # BEFORE INSERT trigger sees — so airtightness on INSERT alone would be a sentence, not a bound.
  # It would also silently narrow a legitimate row COPY (a restore, a clone) down to whatever
  # `max_sessions` a join had lowered it to, which is data loss in the quiet direction.
  #
  # A `CHECK (enrolled_max_sessions = max_sessions)` is not the alternative either: a CHECK is
  # evaluated on UPDATE as well, so the first join that lowers `max_sessions` below the grant
  # would be refused by it — and that lowering is the feature.
  #
  # It fires on INSERT only. An UPDATE trigger filling it would be a second way to write the
  # column. Today `put_enrolled_max_sessions/1`, inside `create_changeset/2`, is the only write
  # to it under `lib/` — one `git grep enrolled_max_sessions lib/` re-checks that.
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
