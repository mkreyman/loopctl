defmodule Loopctl.Workers.TagBackfillWorkerTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Workers.TagBackfillWorker

  defmodule Suggesting do
    @moduledoc false
    @behaviour Loopctl.Knowledge.Tagger
    @impl true
    def suggest(_scope, _article, vocabulary, _opts) do
      # Echo the vocabulary back so a test can prove the worker actually SHOWED it. A tagger
      # that invents strings is exactly the behaviour this feature exists to stop.
      {:ok, Enum.take(vocabulary, 2)}
    end
  end

  defmodule Erroring do
    @moduledoc false
    @behaviour Loopctl.Knowledge.Tagger
    @impl true
    def suggest(_scope, _article, _vocabulary, _opts), do: {:error, :no_api_key}
  end

  defp published(tenant_id, tags) do
    fixture(:article, %{tenant_id: tenant_id, status: :published, tags: tags})
  end

  defp reload(id), do: AdminRepo.get!(Article, id)

  describe "backfill/2" do
    test "re-tags the thin article, from the established vocabulary" do
      tenant = fixture(:tenant)
      # Three well-tagged articles establish the vocabulary...
      for _ <- 1..3, do: published(tenant.id, ["chunking", "retrieval", "embeddings"])
      # ...and one thin one is the candidate.
      thin = published(tenant.id, ["rls"])

      assert %{candidates: 1, retagged: 1, tags_added: 2} =
               TagBackfillWorker.backfill(tenant.id, tagger_impl: Suggesting)

      tags = reload(thin.id).tags
      assert "rls" in tags, "an existing tag must never be dropped"
      assert length(tags) == 3
      # The added tags came from the vocabulary the corpus already uses, not from thin air.
      assert Enum.all?(tags -- ["rls"], &(&1 in ["chunking", "retrieval", "embeddings"]))
    end

    test "a well-tagged article is not a candidate" do
      tenant = fixture(:tenant)
      published(tenant.id, ["chunking", "retrieval", "embeddings"])

      assert %{candidates: 0, retagged: 0} =
               TagBackfillWorker.backfill(tenant.id, tagger_impl: Suggesting)
    end

    test "is idempotent: a second run finds nothing" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: published(tenant.id, ["chunking", "retrieval", "embeddings"])
      published(tenant.id, ["rls"])

      assert %{retagged: 1} = TagBackfillWorker.backfill(tenant.id, tagger_impl: Suggesting)
      assert %{candidates: 0} = TagBackfillWorker.backfill(tenant.id, tagger_impl: Suggesting)
    end

    test "a provider failure leaves the article ELIGIBLE for the next run" do
      # The opposite would be worse than doing nothing: a transient outage would permanently
      # exclude every article it touched, silently, with no way to tell which.
      tenant = fixture(:tenant)
      for _ <- 1..3, do: published(tenant.id, ["chunking", "retrieval", "embeddings"])
      thin = published(tenant.id, ["rls"])

      assert %{candidates: 1, retagged: 0, skipped: 1} =
               TagBackfillWorker.backfill(tenant.id, tagger_impl: Erroring)

      assert reload(thin.id).metadata["retagged_at"] == nil
      assert %{candidates: 1} = TagBackfillWorker.backfill(tenant.id, tagger_impl: Erroring)
    end

    test "the stamp MERGES into metadata rather than replacing it" do
      # A whole-map write would drop `doc_id` and the source fields a capture put there —
      # the same defect that made `lifecycle_entered_at` a column instead of a metadata key.
      tenant = fixture(:tenant)
      for _ <- 1..3, do: published(tenant.id, ["chunking", "retrieval", "embeddings"])

      thin =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["rls"],
          metadata: %{"doc_id" => "keep-me", "source_type" => "web"}
        })

      TagBackfillWorker.backfill(tenant.id, tagger_impl: Suggesting)

      metadata = reload(thin.id).metadata
      assert metadata["doc_id"] == "keep-me"
      assert metadata["source_type"] == "web"
      assert is_binary(metadata["retagged_at"])
    end

    test "tenant isolation: another tenant's thin article is untouched" do
      a = fixture(:tenant)
      b = fixture(:tenant)
      for _ <- 1..3, do: published(a.id, ["chunking", "retrieval", "embeddings"])
      published(a.id, ["rls"])
      theirs = published(b.id, ["rls"])

      assert %{candidates: 1} = TagBackfillWorker.backfill(a.id, tagger_impl: Suggesting)

      assert reload(theirs.id).tags == ["rls"]
      assert reload(theirs.id).metadata["retagged_at"] == nil
    end

    test "the limit bounds one run, and the next resumes" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: published(tenant.id, ["chunking", "retrieval", "embeddings"])
      for _ <- 1..3, do: published(tenant.id, ["rls"])

      assert %{candidates: 2, retagged: 2} =
               TagBackfillWorker.backfill(tenant.id, limit: 2, tagger_impl: Suggesting)

      assert %{candidates: 1, retagged: 1} =
               TagBackfillWorker.backfill(tenant.id, limit: 2, tagger_impl: Suggesting)
    end
  end

  describe "established_vocabulary/2" do
    test "ranks by how many articles use a tag, and excludes provenance ids" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: published(tenant.id, ["common", "url-42516bb95051"])
      published(tenant.id, ["rare"])

      vocabulary = TagBackfillWorker.established_vocabulary(tenant.id)

      assert hd(vocabulary) == "common", "a tag that groups more must be offered first"
      assert "rare" in vocabulary
      refute "url-42516bb95051" in vocabulary
    end
  end
end
