defmodule Loopctl.Repo.CreateChannelLocksMigrationTest do
  @moduledoc """
  US-52.21 / TC-52.21.5 — the data steps of
  `20261121100000_create_channel_locks.exs`.

  The copy and delete steps are public functions of the migration module, so this test
  runs the SAME SQL the migration runs, against the migrated schema, inside the test's
  sandbox transaction. No DDL runs here: re-running `up/0` would recreate a table every
  async test shares, so the table, index and RLS steps are checked by reading the catalog.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelLock
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Repo.Migrations.CreateChannelLocks
  alias Loopctl.Test.MigrationFile

  @version 20_261_121_100_000

  MigrationFile.require!(CreateChannelLocks, @version)

  defp insert_post(ctx, attrs) do
    now = DateTime.utc_now()

    AdminRepo.insert!(
      struct(
        %ChannelPost{
          tenant_id: ctx.tenant.id,
          attachment_seq: System.unique_integer([:positive]),
          project_id: ctx.project.id,
          agent_id: ctx.agent.id,
          session_id: "s1",
          host: "minis",
          body: "advisory soft-lock: editing x (advisory only — it does not block you)",
          expires_at: DateTime.add(now, 900, :second),
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
  end

  defp locks(tenant_id) do
    AdminRepo.all(
      from(l in ChannelLock, where: l.tenant_id == ^tenant_id, order_by: [asc: l.target])
    )
  end

  test "copies only live claim: posts, deletes every claim: post, and a re-copy inserts nothing" do
    tenant = fixture(:tenant)

    ctx = %{
      tenant: tenant,
      project: fixture(:project, %{tenant_id: tenant.id}),
      agent: fixture(:agent, %{tenant_id: tenant.id})
    }

    now = DateTime.utc_now()

    live = insert_post(ctx, key: "claim:lib/a.ex")
    noted = insert_post(ctx, key: "claim:lib/e.ex", body: "refactoring the parser")
    insert_post(ctx, key: "claim:lib/b.ex", expires_at: DateTime.add(now, -60, :second))

    insert_post(ctx,
      key: "claim:lib/c.ex",
      quarantined_at: now,
      quarantine_reason: "secret_match"
    )

    insert_post(ctx, key: "claim:lib/d.ex", expires_at: DateTime.add(now, 30 * 86_400, :second))
    insert_post(ctx, key: "claim:lib/f.ex", session_id: nil)
    keyless = insert_post(ctx, key: nil, body: "an ordinary post")

    %{num_rows: 2} = AdminRepo.query!(CreateChannelLocks.copy_live_locks_sql())

    # The slot index makes the copy idempotent: a second copy inserts nothing.
    %{num_rows: 0} = AdminRepo.query!(CreateChannelLocks.copy_live_locks_sql())

    assert [a, e] = locks(tenant.id)

    assert {a.target, a.session_id, a.host, a.agent_id} ==
             {"lib/a.ex", "s1", "minis", ctx.agent.id}

    assert a.note == nil
    assert a.expires_at == live.expires_at
    assert e.target == "lib/e.ex"
    assert e.note == noted.body

    AdminRepo.query!(CreateChannelLocks.delete_claim_posts_sql())

    remaining =
      AdminRepo.all(
        from(p in ChannelPost, where: p.tenant_id == ^tenant.id, select: {p.id, p.key})
      )

    assert remaining == [{keyless.id, nil}]

    # With every claim: post gone, a further copy has nothing to read.
    %{num_rows: 0} = AdminRepo.query!(CreateChannelLocks.copy_live_locks_sql())
    assert length(locks(tenant.id)) == 2
  end

  test "the migrated schema has the table, the slot index and RLS, and no soft-lock index" do
    %{rows: indexes} =
      AdminRepo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
        [["channel_locks_slot_uidx", "channel_posts_soft_lock_idx"]]
      )

    assert indexes == [["channel_locks_slot_uidx"]]

    %{rows: [[enabled, forced]]} =
      AdminRepo.query!(
        "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'channel_locks'"
      )

    assert {enabled, forced} == {true, false}
  end
end
