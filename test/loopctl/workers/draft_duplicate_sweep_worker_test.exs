defmodule Loopctl.Workers.DraftDuplicateSweepWorkerTest do
  @moduledoc """
  The weekly drain for the draft queue.

  The queue this worker exists to bound was measured on 2026-08-17: 530 held drafts, of
  which 453 duplicated something already published. The tests below pin the two halves of
  that judgement — a draft WITH a near-identical published neighbour is retired, and a
  draft that merely lacks evidence (no embedding, or no close neighbour) is not.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge.Article
  alias Loopctl.Workers.DraftDuplicateSweepWorker

  # Two unit vectors that are cosine-identical to themselves and cosine-ORTHOGONAL to each
  # other, so a test states the similarity it means instead of hoping a random vector lands
  # on the right side of the threshold.
  defp unit_vector(hot_index) do
    dim = Application.get_env(:loopctl, :embedding_dimensions, 1536)
    for i <- 0..(dim - 1), do: if(i == hot_index, do: 1.0, else: 0.0)
  end

  # A unit vector at a KNOWN cosine similarity to `unit_vector(0)`: [cos, sin, 0...].
  # Needed because an ORTHOGONAL vector scores 0.0 and `0.0 > threshold` is false for
  # every threshold >= 0 — so an orthogonality test passes at ANY threshold and pins
  # nothing. This one sits in the band the threshold actually decides.
  defp vector_at_similarity(cosine) do
    dim = Application.get_env(:loopctl, :embedding_dimensions, 1536)
    sine = :math.sqrt(1.0 - cosine * cosine)

    for i <- 0..(dim - 1) do
      case i do
        0 -> cosine
        1 -> sine
        _ -> 0.0
      end
    end
  end

  defp article(tenant_id, status, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "A body with enough content to be a real article.",
      category: :finding,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: status})
    |> AdminRepo.update!()
  end

  defp embed(tenant_id, article, vector) do
    {:ok, _} = Embeddings.upsert_article_embedding(tenant_id, article, vector)
    article
  end

  defp status_of(id) do
    AdminRepo.one(from(a in Article, where: a.id == ^id, select: a.status))
  end

  describe "retiring published duplicates" do
    test "archives a draft whose nearest published neighbour clears the threshold" do
      tenant = fixture(:tenant)
      vector = unit_vector(0)

      published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, vector))
      draft = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))

      assert :ok =
               perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :archived,
             "a draft cosine-identical to a published article must be retired"

      assert status_of(published.id) == :published,
             "the sweep must never touch the published winner"
    end

    test "leaves a draft whose nearest published neighbour is below the threshold" do
      tenant = fixture(:tenant)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, unit_vector(0)))
      draft = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, unit_vector(1)))

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :draft,
             "an orthogonal draft is novel, not duplicate"
    end

    test "leaves a draft that is merely SIMILAR, not near-identical (pins the threshold)" do
      tenant = fixture(:tenant)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, unit_vector(0)))

      # 0.90 — close enough that a careless threshold would sweep it, far enough that
      # the 2026-08-17 drain found genuine judgement was still required in this band.
      draft =
        tenant.id
        |> article(:draft)
        |> then(&embed(tenant.id, &1, vector_at_similarity(0.90)))

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :draft,
             "0.90 is below the 0.95 retirement threshold — lowering the threshold must " <>
               "break this test, not silently widen what the sweep destroys"
    end

    test "archives a draft just ABOVE the threshold" do
      tenant = fixture(:tenant)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, unit_vector(0)))

      draft =
        tenant.id
        |> article(:draft)
        |> then(&embed(tenant.id, &1, vector_at_similarity(0.99)))

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :archived,
             "0.99 clears the threshold — raising the threshold above it must break this " <>
               "test, so the two bounds are pinned from both sides"
    end

    test "does not treat another DRAFT as a duplicate source" do
      tenant = fixture(:tenant)
      vector = unit_vector(0)

      # Two identical drafts and NOTHING published. Retiring either would be the worker
      # inventing a winner: only a published article can settle a draft's fate, because
      # only a published article is what a reader would otherwise already have.
      first = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))
      second = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(first.id) == :draft
      assert status_of(second.id) == :draft
    end
  end

  describe "sparing another worker's reversible retraction" do
    # Consolidation retracts a confirmed duplicate with `unpublish`, never `archive`,
    # so an unattended pass keeps an undo (#605/#606/#608). Its output is BY
    # CONSTRUCTION a draft above this worker's threshold — that similarity is why it
    # was retracted — so without the exclusion the sweep archives exactly the set
    # another worker took care to leave reversible.
    test "never archives a draft that consolidation unpublished" do
      tenant = fixture(:tenant)
      vector = unit_vector(0)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, vector))
      draft = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))

      AdminRepo.insert_all("audit_log", [
        %{
          id: Ecto.UUID.bingenerate(),
          tenant_id: Ecto.UUID.dump!(tenant.id),
          entity_type: "article",
          entity_id: Ecto.UUID.dump!(draft.id),
          action: "article.unpublished",
          actor_type: "worker",
          actor_label: "worker:consolidation",
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      ])

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :draft,
             "consolidation chose a REVERSIBLE retraction; this worker must not convert " <>
               "it into a terminal one a week later"
    end

    test "a draft older than the audit retention window is left alone" do
      # The exemption above is read out of `audit_log`, which `AuditPartitionWorker` DROPs
      # partition-by-partition past `:audit_retention_days` — while this worker runs weekly
      # forever and the drafts it protects live forever. Judging an aged draft on evidence
      # that may already be gone archived the whole aged cohort of consolidation retractions
      # at once, through a door with no way back. Past the horizon the sweep fails CLOSED.
      tenant = fixture(:tenant)
      vector = unit_vector(0)
      days = Application.get_env(:loopctl, :audit_retention_days, 90)
      long_ago = DateTime.add(DateTime.utc_now(), -(days + 7) * 86_400, :second)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, vector))
      draft = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))

      AdminRepo.update_all(
        from(a in Article, where: a.id == ^draft.id),
        set: [updated_at: long_ago]
      )

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :draft,
             "past the audit horizon the exemption cannot be proved, so nothing is archived"
    end

    test "still archives an identical draft that consolidation did NOT retract" do
      tenant = fixture(:tenant)
      vector = unit_vector(0)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, vector))
      draft = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :archived,
             "the exclusion must be scoped to consolidation's output, not disable the sweep"
    end
  end

  describe "absence of evidence" do
    # NB this pins the OUTCOME, not the mechanism. The invariant is protected twice over
    # — the worker's inner join never loads an unembedded draft, and a nil embedding
    # yields no neighbours anyway — so swapping the join for a left_join is
    # behaviour-preserving and does NOT fail this test. Verified by mutation, and
    # recorded here so a later reader does not mistake it for a join guard.
    test "never archives an UNEMBEDDED draft, even beside an identical published article" do
      tenant = fixture(:tenant)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, unit_vector(0)))
      # No embedding: the worker cannot know whether this duplicates anything.
      draft = article(tenant.id, :draft)

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant.id})

      assert status_of(draft.id) == :draft,
             "an unembedded draft is unknown, not novel and not duplicate — leave it"
    end
  end

  describe "tenant isolation" do
    test "a published article in tenant B never retires a draft in tenant A" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      vector = unit_vector(0)

      _b_published =
        tenant_b.id |> article(:published) |> then(&embed(tenant_b.id, &1, vector))

      a_draft = tenant_a.id |> article(:draft) |> then(&embed(tenant_a.id, &1, vector))

      assert :ok = perform_job(DraftDuplicateSweepWorker, %{"tenant_id" => tenant_a.id})

      assert status_of(a_draft.id) == :draft,
             "cross-tenant similarity must never settle a draft — that is a data leak " <>
               "wearing a curation verdict"
    end
  end

  describe "all_tenants dispatcher" do
    # `:manual` rather than the suite-wide `testing: :inline` (config/test.exs): under
    # inline mode `Oban.insert` RUNS the child instead of enqueueing it, so there is
    # nothing left to assert the fan-out against.
    test "enqueues one per-tenant job per ACTIVE tenant, and none for an inactive one" do
      active_one = fixture(:tenant)
      active_two = fixture(:tenant)
      inactive = fixture(:tenant, %{status: :suspended})

      result =
        Oban.Testing.with_testing_mode(:manual, fn ->
          DraftDuplicateSweepWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})
        end)

      assert result == :ok

      enqueued_tenant_ids =
        all_enqueued(worker: DraftDuplicateSweepWorker)
        |> Enum.filter(&Map.has_key?(&1.args, "tenant_id"))
        |> Enum.map(& &1.args["tenant_id"])

      assert active_one.id in enqueued_tenant_ids
      assert active_two.id in enqueued_tenant_ids

      refute inactive.id in enqueued_tenant_ids,
             "a suspended tenant must not have its drafts swept"
    end

    test "the dispatcher itself sweeps nothing" do
      tenant = fixture(:tenant)
      vector = unit_vector(0)

      _published = tenant.id |> article(:published) |> then(&embed(tenant.id, &1, vector))
      draft = tenant.id |> article(:draft) |> then(&embed(tenant.id, &1, vector))

      Oban.Testing.with_testing_mode(:manual, fn ->
        DraftDuplicateSweepWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})
      end)

      assert status_of(draft.id) == :draft,
             "the dispatcher must fan out, not sweep — sweeping there would bypass the " <>
               "per-tenant fair-share gate the child clause applies"
    end
  end
end
