defmodule Loopctl.Knowledge.ConsolidationScoringFailureTest do
  @moduledoc """
  The corroboration gate's DEGRADED path: what happens when the similarity read itself fails.

  The failing read is INJECTED (`apply_confirmed_duplicates/2`'s `:similarity_reader`), so
  the module runs async. It used to take the vector tables away with `ALTER TABLE ... RENAME`,
  whose ACCESS EXCLUSIVE lock blocked every concurrent test touching `article_embeddings`
  and forced the module sync. The reader here fails the way an outage does, with a
  connection error, and every other step of the run is the real one.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

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

    # The scoring read fails whichever vector source the tenant reads from: it is the read
    # itself that is replaced. It records that it was asked, so a run that never reached the
    # read cannot pass on the assertions below.
    test_pid = self()

    failing_read = fn tenant_id, ids, signal ->
      send(test_pid, {:scoring_read, tenant_id, Enum.sort(ids), signal})
      raise DBConnection.ConnectionError, "tcp recv: closed"
    end

    # This process's OWN log: the module runs async, and the `refute` below over every
    # process's log would fail on a concurrent consolidation test's line.
    {result, log} =
      Loopctl.OwnLog.with_own_log(fn ->
        Consolidation.apply_confirmed_duplicates(tenant.id, similarity_reader: failing_read)
      end)

    tenant_id = tenant.id
    members = Enum.sort([a.id, b.id])
    assert_received {:scoring_read, ^tenant_id, ^members, :title}

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
