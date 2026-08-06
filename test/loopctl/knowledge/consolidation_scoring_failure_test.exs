defmodule Loopctl.Knowledge.ConsolidationScoringFailureTest do
  @moduledoc """
  The corroboration gate's DEGRADED path: what happens when the similarity read itself fails.

  `async: false` ON PURPOSE, and it is not a style choice. The only honest way to make the
  scoring read fail is to take its tables away, and `ALTER TABLE ... RENAME` acquires an
  ACCESS EXCLUSIVE lock — which blocks or breaks any concurrently-running async test that
  touches `article_embeddings` (it took out `EmbeddingsSideTableReadsTest` when this lived in
  the async consolidation suite). A sync test never runs alongside another, so the lock cannot
  leak. Mirrors `BatchArticleEmbeddingWorkerTest`'s reasoning for its own `async: false`.
  """
  use Loopctl.DataCase, async: false
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Consolidation

  defp published(tenant_id, attrs) do
    base = %{category: :pattern, tags: [], body: "Body #{System.unique_integer([:positive])}."}

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp status(id), do: AdminRepo.get!(Article, id).status

  # Identical vectors => cosine 1.0, so the group would apply if scoring worked.
  defp corroborate_all!(tenant_id) do
    vector = List.duplicate(0.1, 1536)

    Article
    |> where([a], a.tenant_id == ^tenant_id)
    |> AdminRepo.all()
    |> Enum.each(fn a -> {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, vector, nil) end)
  end

  # A FAILED scoring read is not the same as "these members have no vectors", and the
  # difference is load-bearing: treating a DB outage as missing evidence answered it with a
  # BatchArticleEmbeddingWorker job per member of EVERY confirmed group, fired at the same
  # database that just shed the read. Both paths withhold; only one may enqueue.
  test "a FAILED scoring read withholds WITHOUT reporting missing vectors or enqueuing backfill" do
    tenant = fixture(:tenant)

    a =
      published(tenant.id, %{
        title: "AWS CodeDeploy: Traffic Control",
        body: String.duplicate("long winner body ", 20)
      })

    b = published(tenant.id, %{title: "AWS CodeDeploy Traffic Control", body: "short"})

    corroborate_all!(tenant.id)
    {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
    {:ok, _} = Consolidation.run(tenant.id)

    # Break BOTH vector sources, not just one. `score_pairs/2` picks its source from the
    # US-41.1 side-table cutover flag, so breaking only `article_embeddings` leaves a
    # pre-cutover tenant (which is what :test is) reading `articles.embedding` happily, and
    # the test passes while proving nothing. Both are restored immediately either way; the
    # DDL is also inside the sandbox transaction and rolls back with the test.
    {result, log} =
      with_log(fn ->
        AdminRepo.query!("ALTER TABLE article_embeddings RENAME TO article_embeddings_broken")
        AdminRepo.query!("ALTER TABLE articles RENAME COLUMN embedding TO embedding_broken")

        try do
          Consolidation.apply_confirmed_duplicates(tenant.id)
        after
          AdminRepo.query!("ALTER TABLE articles RENAME COLUMN embedding_broken TO embedding")
          AdminRepo.query!("ALTER TABLE article_embeddings_broken RENAME TO article_embeddings")
        end
      end)

    assert %{applied: 0, skipped: 0, uncorroborated: 1} = result
    assert status(a.id) == :published
    assert status(b.id) == :published

    # The LOG is the discriminating observable, not a provider stub: the backfill worker
    # idempotently skips already-embedded articles, so a wrong fan-out never reaches the
    # client and a stub-based assertion passes while proving nothing.
    assert log =~ "similarity scoring failed this run"
    assert log =~ "the cause is a failed read, not a missing vector"

    refute log =~ "carry no embedding",
           "a failed read was misreported as missing vectors — that is what fans out an " <>
             "embedding job per member against the database that just shed the read"
  end
end
