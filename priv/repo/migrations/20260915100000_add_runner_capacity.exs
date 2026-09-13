defmodule Loopctl.Repo.Migrations.AddRunnerCapacity do
  use Ecto.Migration

  # Issue #803: capacity reservation and admission control for the runner pool.
  #
  # Presence carries each runner's `max_sessions` and `in_flight` as the RUNNER reports them,
  # and Presence is a CRDT with no compare-and-set: two dispatchers can both read
  # `in_flight: 0` and both send. The counters that decide are here instead, and a slot is
  # taken with one conditional UPDATE (`Loopctl.Runners.Capacity`):
  #
  #   UPDATE runners SET in_flight = in_flight + 1
  #    WHERE id = $1 AND tenant_id = $2 AND revoked_at IS NULL AND in_flight < max_sessions
  #
  # A dispatch row holds at most one slot at a time, but can hold SEVERAL over its life: a
  # slot released because the push never happened is taken again when the same `dispatch_id`
  # is re-sent. `slot_generation` names each one (incremented on every reservation) and
  # `released_at` marks the current one released. A release names the generation it means
  # and sets `released_at` only `WHERE released_at IS NULL AND slot_generation = $g`, so a
  # release replayed for an earlier slot can never free a later one. The invariant the heal
  # sweep restores is `runners.in_flight = count of this runner's unreleased dispatches`.
  #
  # `delivery` is the ONE decision about a reservation's fate, and both processes a broadcast
  # wakes race for it under the row lock: the channel that pushes sets `pushed`, a channel
  # that drops sets `dropped` and releases the slot, and whichever commits second respects
  # what it finds. Without it the two ran as independent transactions in either order, and a
  # dropping channel could free the slot of a session the pushing one then started.
  #
  # `reserved_at`, `delivery` and `wall_clock_seconds` give every unreleased slot an end: one
  # never delivered under this reservation is presumed gone after a short bound; one PUSHED
  # but never answered goes after a reply grace, since a runner answers every dispatch it
  # took; and an accepted one ends with the runner's own wall clock plus a grace. The CHECK
  # makes an unbounded reservation unrepresentable.
  #
  # Adding a NOT NULL column with a constant default rewrites no rows (PG 11+). The CHECKs
  # validate by scanning, which is cheap on these tables (a handful of runners, and a ledger
  # that nothing in production writes yet). Dispatches recorded before this migration never
  # took a slot, so they are marked released: counting them would pin capacity that was
  # never reserved.
  def up do
    alter table(:runners) do
      add :max_sessions, :integer, null: false, default: 2
      add :in_flight, :integer, null: false, default: 0
    end

    create constraint(:runners, :runners_max_sessions_range,
             check: "max_sessions BETWEEN 1 AND 64"
           )

    create constraint(:runners, :runners_in_flight_range,
             check: "in_flight >= 0 AND in_flight <= max_sessions"
           )

    alter table(:runner_dispatches) do
      add :released_at, :utc_datetime_usec, null: true
      add :reserved_at, :utc_datetime_usec, null: true
      add :slot_generation, :bigint, null: false, default: 0
      add :delivery, :text, null: true
      add :wall_clock_seconds, :integer, null: true
    end

    create constraint(:runner_dispatches, :runner_dispatches_delivery,
             check: "delivery IS NULL OR delivery IN ('pushed', 'dropped')"
           )

    execute "UPDATE runner_dispatches SET released_at = now() WHERE released_at IS NULL"

    create constraint(:runner_dispatches, :runner_dispatches_slot_generation_nonneg,
             check: "slot_generation >= 0"
           )

    create constraint(:runner_dispatches, :runner_dispatches_wall_clock_positive,
             check: "wall_clock_seconds IS NULL OR wall_clock_seconds > 0"
           )

    create constraint(:runner_dispatches, :runner_dispatches_unreleased_bounded,
             check:
               "released_at IS NOT NULL OR " <>
                 "(wall_clock_seconds IS NOT NULL AND reserved_at IS NOT NULL AND slot_generation > 0)"
           )

    # The heal sweep's and the pool's read: a runner's live reservations.
    create index(:runner_dispatches, [:tenant_id, :runner_id],
             where: "released_at IS NULL",
             name: :runner_dispatches_unreleased_idx
           )
  end

  def down do
    drop index(:runner_dispatches, [:tenant_id, :runner_id],
           name: :runner_dispatches_unreleased_idx
         )

    drop constraint(:runner_dispatches, :runner_dispatches_unreleased_bounded)
    drop constraint(:runner_dispatches, :runner_dispatches_wall_clock_positive)
    drop constraint(:runner_dispatches, :runner_dispatches_slot_generation_nonneg)
    drop constraint(:runner_dispatches, :runner_dispatches_delivery)

    alter table(:runner_dispatches) do
      remove :wall_clock_seconds
      remove :delivery
      remove :slot_generation
      remove :reserved_at
      remove :released_at
    end

    drop constraint(:runners, :runners_in_flight_range)
    drop constraint(:runners, :runners_max_sessions_range)

    alter table(:runners) do
      remove :in_flight
      remove :max_sessions
    end
  end
end
