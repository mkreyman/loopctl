defmodule Loopctl.Workers.RetrievalMetricsWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

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
end
