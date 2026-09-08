defmodule Loopctl.Knowledge.UsageStampWriterBehaviour do
  @moduledoc """
  Injectable contract for the `AdminRepo.update_all/2` statements
  `Loopctl.Knowledge.Importance` writes the usage stamp with (#790).

  ## Why this behaviour exists

  The FOURTH gate value, `:write_failed`, is the one `Loopctl.Knowledge.UsageScanBehaviour`
  cannot reach: it is produced by `guarded/2` rescuing a raise (or catching an exit) from a
  write, after the aggregate has already succeeded. Under the Sandbox those writes cannot
  fail — a valid `update_all` against an owned connection commits — so the gate was
  assertable only by feeding the write deliberately malformed rows, which proves the value
  is produced by a query builder rejecting garbage rather than by a database that went away.

  It is deliberately shaped as the Ecto call and NOT as the domain operation
  (`set_count`/`clear_absent`): the two statements' predicates carry the tenant isolation
  (`AdminRepo` is BYPASSRLS, so the explicit `tenant_id` equality on every statement IS the
  isolation) plus the `IS DISTINCT FROM` and `IS NOT NULL` narrowing that the module's own
  comments explain. Moving them behind a domain callback would move that reasoning into an
  adapter and let a second implementation quietly drop a predicate. Here the queries stay in
  `Importance`, and only the one line that ships them to the database is swappable.

  Two call sites reach this, and both are separately gated: the per-day-group SET
  (`set_one/3`, which HALTS the reduce and leaves the run partially stamped) and the CLEAR
  (`clear_step/3`, which runs after every SET committed). They produce the same gate value
  by different routes, so each needs its own test.

  ## Implementations

    * Production/dev — `Loopctl.Knowledge.UsageStampWriter` (delegates to
      `Loopctl.AdminRepo`; the default, so no config key is required).
    * Test — `Loopctl.MockKnowledgeUsageStampWriter` (a Mox mock; wired via
      `config/test.exs`). The `Loopctl.DataCase` default stub DELEGATES to the real writer,
      so every existing test writes real rows and reads them back unchanged.

  Resolved by `Importance` with config-based DI:
  `Application.get_env(:loopctl, :knowledge_usage_stamp_writer, Loopctl.Knowledge.UsageStampWriter)`.
  """

  @doc """
  Applies `updates` to every row `queryable` selects, exactly as
  `Loopctl.AdminRepo.update_all/2` does, returning `{rows_changed, nil}`.

  It may RAISE or EXIT; the caller's `guarded/2` is what turns either into the
  `:write_failed` gate. An implementation must NOT report a failed write as `{0, nil}` — the
  run would then be recorded as a healthy night on which nothing had moved, which is exactly
  what a steady-state night looks like.
  """
  @callback update_all(queryable :: Ecto.Queryable.t(), updates :: keyword()) ::
              {non_neg_integer(), nil | [term()]}
end
