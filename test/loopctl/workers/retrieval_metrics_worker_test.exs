defmodule Loopctl.Workers.RetrievalMetricsWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.RetrievalMetricSnapshot
  alias Loopctl.Workers.RetrievalMetricsWorker

  test "all_tenants mode snapshots each active tenant (yesterday), skipping suspended" do
    # Oban runs :inline in test, so the fanned-out per-tenant jobs execute synchronously.
    active = fixture(:tenant)
    suspended = fixture(:tenant, %{status: :suspended})
    yesterday = Date.add(DateTime.utc_now() |> DateTime.to_date(), -1)

    for tenant <- [active, suspended] do
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        api_key_id: key.id,
        article_id: article.id,
        access_type: "search",
        accessed_at: DateTime.new!(yesterday, ~T[12:00:00], "Etc/UTC")
      })
    end

    assert :ok = RetrievalMetricsWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

    assert AdminRepo.get_by(RetrievalMetricSnapshot, tenant_id: active.id, day: yesterday)
    refute AdminRepo.get_by(RetrievalMetricSnapshot, tenant_id: suspended.id, day: yesterday)
  end

  test "per-tenant mode records a snapshot for the given day" do
    tenant = fixture(:tenant)
    {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    article = fixture(:article, %{tenant_id: tenant.id, status: :published})

    day = ~D[2026-06-15]

    fixture(:article_access_event, %{
      tenant_id: tenant.id,
      api_key_id: key.id,
      article_id: article.id,
      access_type: "search",
      accessed_at: DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    })

    assert :ok =
             RetrievalMetricsWorker.perform(%Oban.Job{
               args: %{"tenant_id" => tenant.id, "day" => "2026-06-15"}
             })

    snap = AdminRepo.get_by(RetrievalMetricSnapshot, tenant_id: tenant.id, day: day)
    assert snap.searched == 1
    assert snap.followed_through == 0
  end

  test "the snapshot carries the call-level fields (#582)" do
    tenant = fixture(:tenant)
    {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    a = fixture(:article, %{tenant_id: tenant.id, status: :published})
    b = fixture(:article, %{tenant_id: tenant.id, status: :published})

    day = ~D[2026-06-15]
    search_id = Ecto.UUID.generate()

    # One search CALL surfacing two results, one of which the agent opened: precision
    # (per surfaced result) is 0.5 while search_follow_through (per call) is 1.0.
    for article <- [a, b] do
      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        api_key_id: key.id,
        article_id: article.id,
        access_type: "search",
        metadata: %{"search_id" => search_id, "results_returned" => 7},
        accessed_at: DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
      })
    end

    fixture(:article_access_event, %{
      tenant_id: tenant.id,
      api_key_id: key.id,
      article_id: a.id,
      access_type: "get",
      accessed_at: DateTime.new!(day, ~T[12:05:00], "Etc/UTC")
    })

    assert :ok =
             RetrievalMetricsWorker.perform(%Oban.Job{
               args: %{"tenant_id" => tenant.id, "day" => "2026-06-15"}
             })

    snap = AdminRepo.get_by(RetrievalMetricSnapshot, tenant_id: tenant.id, day: day)
    assert snap.searched == 2
    assert snap.precision == 0.5
    assert snap.searches == 1
    assert snap.searches_with_follow_through == 1
    assert snap.search_follow_through == 1.0
    assert snap.results_returned == 7
  end

  describe "late references (the day before the cron target is re-snapshotted)" do
    # `compute_referenced/3` buckets a reference by the day the article was SURFACED, and
    # puts no upper bound on the reference row's own timestamp. So a recall at 17:00 whose
    # `recall_referenced` arrives the next morning belongs to a snapshot that was written
    # hours earlier. Nothing else revisits a written day, so before the lookback that
    # reference was permanently uncounted.
    test "a reference posted the morning AFTER its surfacing day still lands" do
      tenant = fixture(:tenant)
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      today = DateTime.utc_now() |> DateTime.to_date()
      # The cron target is yesterday, so the SURFACING day is the one it looks back to.
      surfaced_on = Date.add(today, -2)
      referenced_on = Date.add(today, -1)
      search_id = Ecto.UUID.generate()

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        api_key_id: key.id,
        article_id: article.id,
        access_type: "search",
        metadata: %{"search_id" => search_id, "results_returned" => 1},
        accessed_at: DateTime.new!(surfaced_on, ~T[17:00:00], "Etc/UTC")
      })

      # The run that closed the surfacing day, BEFORE the reference existed.
      assert :ok =
               RetrievalMetricsWorker.perform(%Oban.Job{
                 args: %{"tenant_id" => tenant.id, "day" => Date.to_iso8601(surfaced_on)}
               })

      first = AdminRepo.get_by(RetrievalMetricSnapshot, tenant_id: tenant.id, day: surfaced_on)
      assert first.searched == 1
      assert first.referenced == 0

      # An explicit "day" is a backfill of exactly that day and must not rewrite its
      # neighbour, so nothing was written for the day before it.
      refute AdminRepo.get_by(RetrievalMetricSnapshot,
               tenant_id: tenant.id,
               day: Date.add(surfaced_on, -1)
             )

      # The agent posts the reference the next morning.
      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        api_key_id: key.id,
        article_id: article.id,
        access_type: "referenced",
        origin_search_id: search_id,
        accessed_at: DateTime.new!(referenced_on, ~T[09:00:00], "Etc/UTC")
      })

      # The CRON path: target is yesterday, and it re-snapshots the day before it.
      assert :ok = RetrievalMetricsWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert AdminRepo.get_by(RetrievalMetricSnapshot,
               tenant_id: tenant.id,
               day: referenced_on
             ),
             "the cron target day itself must still be snapshotted"

      reswept = AdminRepo.get_by(RetrievalMetricSnapshot, tenant_id: tenant.id, day: surfaced_on)

      assert reswept.referenced == 1,
             "the late reference must be counted against the day the article was SURFACED"

      # `reference_rate` is derived (`referenced / searched`), never stored — so the
      # rewritten row publishes the corrected rate without a backfill.
      assert reswept.searched == 1
    end

    test "the lookback is bounded and does not walk backwards" do
      tenant = fixture(:tenant)
      today = DateTime.utc_now() |> DateTime.to_date()

      assert :ok = RetrievalMetricsWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      days =
        AdminRepo.all(
          from(s in RetrievalMetricSnapshot, where: s.tenant_id == ^tenant.id, select: s.day)
        )

      assert Enum.sort(days) == Enum.sort([Date.add(today, -1), Date.add(today, -2)]),
             "one cron run writes exactly its target day and the single day before it"
    end
  end
end
