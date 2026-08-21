defmodule Loopctl.Workers.StructuralLinksWorkerTest do
  @moduledoc """
  The weekly cadence for the US-42.1 provenance harvest (#725).

  Several of these tests pin DECISIONS rather than mechanics, because each is a place where
  the obvious implementation is wrong at production scale:

  * the unattended floor is **25**, not the library default of 3 — measured on the hosted
    corpus, 3 mints ~1,900 extra hubs from the smallest sources, where a usable name is
    least likely;
  * a shed heavy read must SNOOZE, not fail — the harvest returns
    `{:error, :heavy_read_overloaded}` under exactly the load the shedder exists to
    relieve, and burning attempts there is how a tenant loses a week's hubs;
  * the fan-out skips a suspended tenant (its corpus is not ours to keep writing to) AND a
    tenant with no published article at all — a signup that never wrote anything must not
    cost a job insert and a scan every week forever.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.MockStructuralLinksHarvester
  alias Loopctl.Workers.StructuralLinksWorker

  defp article(tenant_id, tags) do
    fixture(:article, %{tenant_id: tenant_id, tags: tags, status: :published})
  end

  defp source_hubs(tenant_id) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: fragment("? ->> 'hub_kind' = 'source'", a.metadata),
      select: a
    )
    |> AdminRepo.all()
  end

  defp derived_edges(tenant_id) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id and l.relationship_type == :derived_from,
      select: l.target_article_id
    )
    |> AdminRepo.all()
  end

  defp harvest_audits(tenant_id) do
    from(e in AuditLog,
      where: e.tenant_id == ^tenant_id,
      where: e.action == "knowledge.structural_links_harvested",
      select: e
    )
    |> AdminRepo.all()
  end

  describe "the unattended sibling floor" do
    test "harvests a source at 25 members and skips one at 24" do
      tenant = fixture(:tenant)

      for _ <- 1..25, do: article(tenant.id, ["book-at-floor"])
      for _ <- 1..24, do: article(tenant.id, ["book-below-floor"])

      assert :ok = perform_job(StructuralLinksWorker, %{"tenant_id" => tenant.id})

      assert [hub] = source_hubs(tenant.id)
      assert hub.metadata["source_key"] == "book-at-floor"

      assert length(derived_edges(tenant.id)) == 25,
             "the 24-member source must contribute no edges — dropping the unattended " <>
               "floor back to the library default of 3 mints ~1,900 extra digest-named " <>
               "hubs on the live corpus (#725), so this asserts the floor from both sides"
    end

    test "passes the floor to the harvester rather than letting the library default apply" do
      tenant = fixture(:tenant)

      expect(MockStructuralLinksHarvester, :harvest, fn passed_tenant, opts ->
        assert passed_tenant == tenant.id
        assert Keyword.fetch!(opts, :min_siblings) == 25
        {:ok, blank_report()}
      end)

      assert :ok = perform_job(StructuralLinksWorker, %{"tenant_id" => tenant.id})
    end
  end

  describe "a shed corpus scan" do
    test "snoozes the tenant instead of consuming an attempt" do
      tenant = fixture(:tenant)

      expect(MockStructuralLinksHarvester, :harvest, fn _tenant, _opts ->
        {:error, :heavy_read_overloaded}
      end)

      assert {:snooze, seconds} = perform_job(StructuralLinksWorker, %{"tenant_id" => tenant.id})
      assert seconds > 0
    end

    test "writes no audit entry for a run that never happened" do
      tenant = fixture(:tenant)

      expect(MockStructuralLinksHarvester, :harvest, fn _tenant, _opts ->
        {:error, :heavy_read_overloaded}
      end)

      assert {:snooze, _} = perform_job(StructuralLinksWorker, %{"tenant_id" => tenant.id})
      assert harvest_audits(tenant.id) == []
    end

    test "cancels instead of snoozing forever once the shed count is capped" do
      tenant = fixture(:tenant)

      expect(MockStructuralLinksHarvester, :harvest, fn _tenant, _opts ->
        {:error, :heavy_read_overloaded}
      end)

      # A snooze raises `max_attempts` in lockstep, so it can NEVER exhaust into
      # `discarded`: a tenant shedding persistently would re-scan the corpus every five
      # minutes forever while nothing fails and nothing alerts, and each Sunday's cron
      # would add another job doing the same.
      assert {:cancel, :heavy_read_overloaded} =
               perform_job(StructuralLinksWorker, %{"tenant_id" => tenant.id}, attempt: 12)
    end
  end

  describe "the audit record" do
    test "carries the report, including its reconciliation verdict" do
      tenant = fixture(:tenant)
      for _ <- 1..25, do: article(tenant.id, ["book-audited"])

      assert :ok = perform_job(StructuralLinksWorker, %{"tenant_id" => tenant.id})

      assert [entry] = harvest_audits(tenant.id)
      assert entry.actor_label == "worker:structural_links"
      assert entry.new_state["hubs_created"] == 1
      assert entry.new_state["edges_created"] == 25
      assert entry.new_state["sources_qualifying"] == 1
      assert entry.new_state["distinct_hubs"] == 1

      assert entry.new_state["reconciled"] == true,
             "a source landing on a hub that does not carry its tag is how the #724 hub " <>
               "merge shows up — the verdict has to survive in the audit log, not only " <>
               "in a log line"
    end
  end

  describe "all_tenants fan-out" do
    test "harvests each active tenant and leaves a suspended one alone" do
      active = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})

      for _ <- 1..25, do: article(active.id, ["book-active"])
      for _ <- 1..25, do: article(suspended.id, ["book-suspended"])

      assert :ok = StructuralLinksWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

      assert [_hub] = source_hubs(active.id)
      assert source_hubs(suspended.id) == []
    end

    test "an active tenant with no published corpus is not enqueued at all" do
      # The recorded fan-out finding's test: what shrinks the enumerated set? A tenant
      # that signed up and never wrote anything has nothing to harvest, so it must not
      # cost a job insert and a scan every week forever. No job means no audit entry.
      with_corpus = fixture(:tenant)
      empty = fixture(:tenant)
      drafts_only = fixture(:tenant)

      for _ <- 1..25, do: article(with_corpus.id, ["book-real"])
      fixture(:article, %{tenant_id: drafts_only.id, tags: ["book-draft"], status: :draft})

      assert :ok = StructuralLinksWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

      assert [_entry] = harvest_audits(with_corpus.id)
      assert harvest_audits(empty.id) == []
      assert harvest_audits(drafts_only.id) == []
    end

    test "a tenant's harvest never reaches another tenant's corpus" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      for _ <- 1..25, do: article(tenant_a.id, ["book-shared-tag"])
      for _ <- 1..25, do: article(tenant_b.id, ["book-shared-tag"])

      assert :ok = perform_job(StructuralLinksWorker, %{"tenant_id" => tenant_a.id})

      assert [_hub] = source_hubs(tenant_a.id)
      assert source_hubs(tenant_b.id) == []
      assert derived_edges(tenant_b.id) == []
    end
  end

  defp blank_report do
    %{
      hubs_created: 0,
      hubs_resolved: 0,
      hubs_adopted: 0,
      hub_failures: 0,
      hubs_unattributed: 0,
      edges_created: 0,
      sources_below_floor: 0,
      articles_without_source: 0,
      min_siblings: 25,
      sources_qualifying: 0,
      distinct_hubs: 0,
      shared_hubs: 0,
      reconciled: true
    }
  end
end
