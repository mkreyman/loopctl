defmodule Loopctl.Knowledge.ImportanceTest do
  # The nightly usage stamp behind the importance ranking prior (#790).
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Importance

  @now ~U[2026-07-21 12:00:00Z]

  defp article(tenant_id, attrs \\ %{}) do
    fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))
  end

  # One access event, `days_ago` days before @now at a fixed time of day, so a test that
  # means "two distinct days" cannot accidentally straddle a UTC boundary.
  defp read(tenant_id, article_id, days_ago, opts \\ []) do
    at =
      @now
      |> DateTime.add(-days_ago * 86_400, :second)
      |> then(&Keyword.get(opts, :at, &1))

    fixture(:article_access_event, %{
      tenant_id: tenant_id,
      article_id: article_id,
      access_type: Keyword.get(opts, :access_type, "get"),
      accessed_at: at
    })
  end

  defp stamp(tenant_id), do: Importance.stamp(tenant_id, now: @now)

  defp read_days(article_id) do
    AdminRepo.one(from(a in Article, where: a.id == ^article_id, select: a.read_day_count))
  end

  describe "what it counts" do
    test "distinct read DAYS, not raw reads" do
      # THE pinning property, and the reason this column is days rather than a count: a
      # `knowledge_get` loop inflates a count and cannot inflate a day. Five reads on two
      # days must score exactly the same as two reads on two days.
      tenant = fixture(:tenant)
      looped = article(tenant.id)
      steady = article(tenant.id)

      for _ <- 1..3, do: read(tenant.id, looped.id, 1)
      read(tenant.id, looped.id, 2)
      read(tenant.id, steady.id, 1)
      read(tenant.id, steady.id, 2)

      assert %{gate: :open} = stamp(tenant.id)

      assert read_days(looped.id) == 2
      assert read_days(steady.id) == 2
    end

    test "many reads inside ONE day score 1" do
      tenant = fixture(:tenant)
      spammed = article(tenant.id)

      for hour <- 0..9 do
        read(tenant.id, spammed.id, 1, at: DateTime.add(@now, -86_400 + hour * 3600, :second))
      end

      stamp(tenant.id)

      assert read_days(spammed.id) == 1
    end

    test "a drill is NOT counted" do
      # #569/#572: being SHOWN by an index must not produce the rank that showed it. This
      # module inherits the exclusion from Knowledge.heat_read_access_types/0 rather than
      # restating it, so the assertion is that it really did.
      tenant = fixture(:tenant)
      drilled = article(tenant.id)
      opened = article(tenant.id)

      read(tenant.id, drilled.id, 1, access_type: "drill")
      read(tenant.id, drilled.id, 2, access_type: "drill")
      read(tenant.id, opened.id, 1)

      stamp(tenant.id)

      assert read_days(drilled.id) == nil
      assert read_days(opened.id) == 1
    end

    test "a search impression is NOT counted" do
      # #563: a `search` row is one per RESULT of a ranked query, so counting it would make
      # the prior a tally of past ranker output and re-couple it to embedding similarity.
      tenant = fixture(:tenant)
      surfaced = article(tenant.id)

      read(tenant.id, surfaced.id, 1, access_type: "search")

      stamp(tenant.id)

      assert read_days(surfaced.id) == nil
    end

    test "a read older than the window is not counted" do
      tenant = fixture(:tenant)
      stale = article(tenant.id)
      recent = article(tenant.id)

      read(tenant.id, stale.id, Importance.window_days() + 5)
      read(tenant.id, recent.id, 1)

      stamp(tenant.id)

      assert read_days(stale.id) == nil
      assert read_days(recent.id) == 1
    end

    test "an unread article is left NULL, which is exactly neutral" do
      tenant = fixture(:tenant)
      never_read = article(tenant.id)

      assert %{stamped: 0, cleared: 0} = stamp(tenant.id)
      assert read_days(never_read.id) == nil
    end
  end

  describe "reconciliation" do
    test "an article that falls out of the window is CLEARED, not left with a stale boost" do
      # Without this the prior is a ratchet: anything ever popular keeps its boost forever,
      # and the stamp becomes an all-time counter wearing a window's name.
      tenant = fixture(:tenant)
      was_hot = article(tenant.id)

      read(tenant.id, was_hot.id, 1)
      stamp(tenant.id)
      assert read_days(was_hot.id) == 1

      # The same corpus, a year later: the read is outside the window.
      later = DateTime.add(@now, 400 * 86_400, :second)

      assert %{cleared: 1} = Importance.stamp(tenant.id, now: later)
      assert read_days(was_hot.id) == nil
    end

    test "a second run over an unchanged corpus writes nothing" do
      # The steady-state night. `IS DISTINCT FROM` is what makes this true, and it is not
      # cosmetic: a plain inequality against a NULL column matches nothing, so the FIRST
      # run would write nothing at all.
      tenant = fixture(:tenant)
      a = article(tenant.id)
      read(tenant.id, a.id, 1)

      assert %{stamped: 1, cleared: 0} = stamp(tenant.id)
      assert %{stamped: 0, cleared: 0} = stamp(tenant.id)
      assert read_days(a.id) == 1
    end

    test "a rising count is rewritten" do
      tenant = fixture(:tenant)
      a = article(tenant.id)
      read(tenant.id, a.id, 1)
      stamp(tenant.id)

      read(tenant.id, a.id, 2)
      assert %{stamped: 1} = stamp(tenant.id)
      assert read_days(a.id) == 2
    end
  end

  describe "what it must not touch" do
    test "it does not move updated_at or content_changed_at" do
      # Being READ is not being EDITED. A changeset write would bump `updated_at` on every
      # read article every night, which the staleness lint reads through its coalesce for
      # any row with a null content_changed_at — the whole corpus would look freshly
      # maintained because it was being looked at.
      tenant = fixture(:tenant)
      a = article(tenant.id)
      read(tenant.id, a.id, 1)

      before = AdminRepo.get!(Article, a.id)
      stamp(tenant.id)
      after_stamp = AdminRepo.get!(Article, a.id)

      # Precondition: the stamp actually wrote, or the equalities below hold vacuously.
      assert after_stamp.read_day_count == 1
      assert after_stamp.updated_at == before.updated_at
      assert after_stamp.content_changed_at == before.content_changed_at
    end

    test "it never stamps a SYSTEM canonical" do
      # `read_day_count` is one column on a row several tenants read, so one tenant's usage
      # must not decide a shared row's rank for everyone. A canonical stays NULL — neutral.
      tenant = fixture(:tenant)

      {:ok, canonical} =
        Knowledge.create_article(tenant.id, %{
          title: "Shared canon #{System.unique_integer([:positive])}",
          body: "canon body",
          category: :reference,
          scope: :system,
          status: :published
        })

      assert is_nil(canonical.tenant_id)

      read(tenant.id, canonical.id, 1)
      read(tenant.id, canonical.id, 2)

      assert %{stamped: 0} = stamp(tenant.id)
      assert read_days(canonical.id) == nil
    end
  end

  describe "tenant isolation" do
    test "tenant A's stamp never writes tenant B's article" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      mine = article(tenant_a.id)
      theirs = article(tenant_b.id)

      read(tenant_a.id, mine.id, 1)
      read(tenant_b.id, theirs.id, 1)
      read(tenant_b.id, theirs.id, 2)

      assert %{stamped: 1} = stamp(tenant_a.id)

      assert read_days(mine.id) == 1
      assert read_days(theirs.id) == nil
    end

    test "tenant A's stamp never CLEARS tenant B's article" do
      # The clear statement is the wider of the two writes — it is a NOT IN over the whole
      # corpus — so its tenant predicate is the one that matters most.
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      mine = article(tenant_a.id)
      theirs = article(tenant_b.id)

      read(tenant_b.id, theirs.id, 1)
      stamp(tenant_b.id)
      assert read_days(theirs.id) == 1

      # Tenant A reads something of its own, so its clear statement runs with a non-empty
      # id list — the branch that could reach across if the predicate were missing.
      read(tenant_a.id, mine.id, 1)
      stamp(tenant_a.id)

      assert read_days(theirs.id) == 1
    end

    test "a tenant with no events at all clears only its own rows" do
      # The EMPTY-id-list branch of the clear, which is a different statement from the one
      # above and would be the easiest place to drop a predicate.
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      mine = article(tenant_a.id)
      theirs = article(tenant_b.id)

      read(tenant_b.id, theirs.id, 1)
      stamp(tenant_b.id)

      {1, _} =
        AdminRepo.update_all(
          from(a in Article, where: a.id == ^mine.id),
          set: [read_day_count: 42]
        )

      assert %{stamped: 0, cleared: 1} = stamp(tenant_a.id)

      assert read_days(mine.id) == nil
      assert read_days(theirs.id) == 1
    end
  end

  describe "the tally" do
    test "reports gate :open and both counts on a normal run" do
      tenant = fixture(:tenant)
      a = article(tenant.id)
      read(tenant.id, a.id, 1)

      assert %{stamped: 1, cleared: 0, truncated: false, gate: :open} = stamp(tenant.id)
    end
  end
end
