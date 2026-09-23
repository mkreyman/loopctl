defmodule Loopctl.Repo.Migrations.AddRunnersUsageExhausted do
  @moduledoc """
  An exhausted subscription is not capacity (epic 44, US-44.6; runner contract 1.17.0).

  - `usage_exhausted_until` — until when this runner's subscription is declared exhausted. Set
    from a `status` message's `usage` (clamped to `[now + 60s, now + 8 days]`) and by a
    `session_ended` `usage_exhausted`; cleared by `usage.exhausted: false`. NULL is "not
    exhausted", and so is a value in the past — nothing sweeps an expired one, because the
    readers compare against now.
  - `usage_cleared_at` — when a `usage.exhausted: false` last cleared this row. A
    `session_ended` `usage_exhausted` whose dispatch was accepted BEFORE it does not re-mark the
    account: the session saw a fact the refill report has since overtaken.
  - `account_ref` — the opaque value a runner derives from the login it runs sessions under.
    Runners sharing one are exhausted TOGETHER: a subscription is per account, not per machine.

  On the `runners` row rather than in Presence meta, so the state survives a node restart and is
  the same on every node — Presence converges only within a cluster, and a runner that
  reconnects to another node would otherwise come back looking fresh.

  The `(tenant_id, account_ref)` index serves the account-wide read every eligibility check
  makes and the account-wide clear. Partial, because a runner that never sent `usage` carries no
  account and is never looked up by one.

  No backfill and no manual step. Additive and nullable, so an old instance still serving during
  the rolling deploy writes rows the new code reads correctly — as not exhausted, which is what
  every existing runner is. The table already has RLS enabled; columns inherit it.
  """

  use Ecto.Migration

  def up do
    alter table(:runners) do
      add :usage_exhausted_until, :utc_datetime_usec, null: true
      add :usage_cleared_at, :utc_datetime_usec, null: true
      add :account_ref, :string, null: true
    end

    # Mirrors `RunnerContract.RunnerUsage`'s bound on the wire: printable ASCII with no
    # whitespace, at most 128 characters. The contract cast refuses anything else first; this
    # is the backstop for a writer that bypasses it.
    create constraint(:runners, :runners_account_ref_shape,
             check: "account_ref IS NULL OR account_ref ~ '^[!-~]{1,128}$'"
           )

    create index(:runners, [:tenant_id, :account_ref],
             where: "account_ref IS NOT NULL",
             name: :runners_tenant_account_ref_idx
           )
  end

  def down do
    drop index(:runners, [:tenant_id, :account_ref], name: :runners_tenant_account_ref_idx)
    drop constraint(:runners, :runners_account_ref_shape)

    alter table(:runners) do
      remove :usage_exhausted_until
      remove :usage_cleared_at
      remove :account_ref
    end
  end
end
