defmodule Loopctl.Repo.ChannelPostsAttachmentsMigrationTest do
  @moduledoc """
  US-52.22 / TC-52.22.4 — the data steps of `20261121110000_channel_posts_attachments.exs`.

  The backfill, clamp and fold steps are public functions of the migration module, so this
  test runs the SAME SQL the migration runs, scoped to this test's tenant, inside the test's
  sandbox transaction. No DDL runs here: re-running `up/0` would alter a table every async
  test shares, so the column, index and check steps are checked by reading the catalog.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Repo.Migrations.ChannelPostsAttachments
  alias Loopctl.Test.MigrationFile

  @version 20_261_121_110_000

  MigrationFile.require!(ChannelPostsAttachments, @version)

  defp insert_post(ctx, project, attrs) do
    at = Keyword.get(attrs, :at, DateTime.utc_now())

    AdminRepo.insert!(
      struct(
        %ChannelPost{
          tenant_id: ctx.tenant.id,
          project_id: project.id,
          agent_id: ctx.agent.id,
          session_id: "s1",
          body: "post",
          # A value the backfill must overwrite.
          attachment_seq: 1_000 + System.unique_integer([:positive]),
          expires_at: DateTime.add(at, 30 * 86_400, :second),
          inserted_at: at,
          updated_at: at
        },
        Keyword.delete(attrs, :at)
      )
    )
  end

  defp run(sql_or_list), do: sql_or_list |> List.wrap() |> Enum.each(&AdminRepo.query!/1)

  test "backfills attachment_seq per project, clamps channel retention, folds keyed slots" do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id})
    p1 = fixture(:project, %{tenant_id: tenant.id})
    p2 = fixture(:project, %{tenant_id: tenant.id})
    ctx = %{tenant: tenant, agent: agent}
    now = DateTime.utc_now()
    days_ago = &DateTime.add(now, -&1 * 86_400, :second)

    old = insert_post(ctx, p1, at: days_ago.(20))
    goal = insert_post(ctx, p1, at: days_ago.(10), key: "session_goal")
    handoff = insert_post(ctx, p1, at: days_ago.(5), key: "handoff:repo#7")
    recent = insert_post(ctx, p1, at: days_ago.(2))
    digest = insert_post(ctx, p1, at: days_ago.(1), key: "escalation-digest:#{p1.id}:2026-11-20")

    quarantined =
      insert_post(ctx, p1,
        at: days_ago.(15),
        quarantined_at: now,
        quarantine_reason: "secret_denylist: body"
      )

    other_old = insert_post(ctx, p2, at: days_ago.(20))
    other_recent = insert_post(ctx, p2, at: days_ago.(2))

    scope = "AND tenant_id = '#{tenant.id}'"
    run(ChannelPostsAttachments.backfill_attachment_seq_sql(scope))
    run(ChannelPostsAttachments.clamp_retention_sql(scope))
    run(ChannelPostsAttachments.fold_keyed_slots_sql(scope))

    get = &AdminRepo.get!(ChannelPost, &1.id)

    # attachment_seq 1..n per project, in insertion order.
    assert Enum.map([old, quarantined, goal, handoff, recent, digest], &get.(&1).attachment_seq) ==
             [1, 2, 3, 4, 5, 6]

    assert Enum.map([other_old, other_recent], &get.(&1).attachment_seq) == [1, 2]

    # The 20-day post is now expired; the 2-day post keeps 5 more days.
    assert DateTime.compare(get.(old).expires_at, now) == :lt
    assert get.(old).expires_at == DateTime.add(old.inserted_at, 7 * 86_400, :second)
    assert get.(recent).expires_at == DateTime.add(recent.inserted_at, 7 * 86_400, :second)

    # The keyed session_goal slot becomes a plain message; the digest's key moves to its
    # idempotency key.
    assert get.(goal).key == nil
    assert get.(digest).key == nil
    assert get.(digest).idempotency_key == "escalation-digest:#{p1.id}:2026-11-20"

    # The handoff row keeps its key and its 30-day expiry; the quarantined row its review
    # window.
    assert get.(handoff).key == "handoff:repo#7"
    assert get.(handoff).expires_at == handoff.expires_at
    assert get.(quarantined).expires_at == quarantined.expires_at

    assert AdminRepo.aggregate(
             from(p in ChannelPost,
               where: p.tenant_id == ^tenant.id and not is_nil(p.key),
               where: not like(p.key, "handoff:%")
             ),
             :count
           ) == 0
  end

  test "the migrated schema carries the columns, the check and both rebuilt indexes" do
    %{rows: indexes} =
      AdminRepo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' " <>
          "AND indexname = ANY($1) ORDER BY indexname",
        [["channel_posts_attachment_seq_uidx", "channel_posts_session_key_uidx"]]
      )

    assert [
             ["channel_posts_attachment_seq_uidx", seq_def],
             ["channel_posts_session_key_uidx", key_def]
           ] =
             indexes

    assert seq_def =~ "COALESCE(story_id, to_holder_id, project_id), attachment_seq"
    assert key_def =~ "WHERE (key ~~ 'handoff:%'::text)"

    %{rows: [[check]]} =
      AdminRepo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conname = 'channel_posts_one_attachment'"
      )

    assert check =~ "story_id IS NOT NULL"

    %{rows: nullability} =
      AdminRepo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'channel_posts' AND column_name = ANY($1) ORDER BY column_name",
        [["attachment_seq", "expires_at", "project_id"]]
      )

    assert nullability == [["attachment_seq", "NO"], ["expires_at", "YES"], ["project_id", "YES"]]
  end
end
