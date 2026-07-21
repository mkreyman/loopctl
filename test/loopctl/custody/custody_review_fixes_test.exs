defmodule Loopctl.CustodyReviewFixesTest do
  @moduledoc """
  US-41.7, second review round. Each test pins a defect the review found in the
  first cut — the ones that could produce a FALSE zero-egress attestation, plus
  the disclosure and pool-budget ones.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Custody
  alias Loopctl.Custody.PostureEntry
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Knowledge.ProposalGate
  alias Loopctl.Test.AllowlistSource

  setup :verify_on_exit!

  @embedding_host "api.openai.com"
  @chat_host "api.anthropic.com"

  setup do
    tenant = fixture(:tenant)

    on_exit(fn ->
      PinCache.invalidate_tenant(tenant.id)
      AllowlistSource.clear()
    end)

    {:ok, tenant: tenant}
  end

  defp all_endpoints_local, do: AllowlistSource.put([@embedding_host, @chat_host])

  defp mark_local_only(tenant_id, project_id \\ nil) do
    {:ok, _} = Egress.enable_local_only(tenant_id, project_id, acknowledge: true)
    PinCache.invalidate_tenant(tenant_id)
    :ok
  end

  defp clear_local_only(tenant_id, project_id \\ nil) do
    {:ok, _} = Egress.clear_local_only(tenant_id, project_id, acknowledge: true)
    PinCache.invalidate_tenant(tenant_id)
    :ok
  end

  defp manual(fun), do: Oban.Testing.with_testing_mode(:manual, fun)

  defp claim!(tenant_id, subject_type, subject_id) do
    {:ok, claim} = Custody.claim(tenant_id, subject_type, subject_id)
    claim
  end

  defp drain_custody, do: Oban.drain_queue(queue: :audit, with_scheduled: true)

  describe "a mid-life local_only CLEAR must not TRUNCATE the sequence" do
    test "a later egressing operation is still recorded, and the claim degrades", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      article = fixture(:article, %{tenant_id: t.id})
      scope = Scope.new(t.id)

      {:ok, %PostureEntry{operation_sequence: 0}} =
        manual(fn -> Custody.record(scope, "article", article.id, :create) end)

      # The tenant clears local_only. Under the first cut this made every later
      # operation `:not_applicable`, allocating NOTHING — so the all-local prefix
      # stayed contiguous up to an unchanged high-water mark and the claim kept
      # reading COMPLETE / no-third-party-egress for a row whose body then left.
      :ok = clear_local_only(t.id)
      # ... and the endpoints are no longer local either.
      AllowlistSource.clear()

      assert {:ok, %PostureEntry{operation_sequence: 1}} =
               manual(fn -> Custody.record(scope, "article", article.id, :reembed) end)

      drain_custody()

      claim = claim!(t.id, "article", article.id)

      assert claim.claim_state == "claim_recorded"
      assert claim.completeness == "complete"
      assert claim.highest_assigned_sequence == 1
      # The honest answer, not the silently-truncated one.
      assert claim.third_party_egress_on_covered_paths == true
      assert claim.posture == "mixed"
    end

    test "a row that never started recording is still NOT recorded after a clear", %{tenant: t} do
      all_endpoints_local()
      article = fixture(:article, %{tenant_id: t.id})

      assert {:ok, :not_applicable} =
               manual(fn ->
                 Custody.record(Scope.new(t.id), "article", article.id, :embed)
               end)

      assert claim!(t.id, "article", article.id).claim_state == "no_claim_recorded"
    end
  end

  describe "a create path that made a provider call records it" do
    test "endpoint_kinds: [:embedding] on a :create records the embedding endpoint",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      article = fixture(:article, %{tenant_id: t.id})

      {:ok, entry} =
        manual(fn ->
          Custody.assign(AdminRepo, Scope.new(t.id), "article", article.id, :create,
            endpoint_kinds: [:embedding]
          )
        end)

      kinds = Enum.map(entry.posture.endpoints, & &1.kind)
      assert kinds == ["embedding"]

      # And a plain create still records nothing — recording an endpoint that was
      # not called would be a falsehood in the other direction.
      other = fixture(:article, %{tenant_id: t.id})

      {:ok, plain} =
        manual(fn -> Custody.assign(AdminRepo, Scope.new(t.id), "article", other.id, :create) end)

      assert plain.posture.endpoints == []
    end

    test "the novelty gate reports whether it embedded", %{tenant: _t} do
      # A caller-supplied vector means NO provider call was made.
      assert %{gate_embedded: false} =
               ProposalGate.assess(
                 Ecto.UUID.generate(),
                 %{"title" => "t", "body" => "b"},
                 embedding: [0.1, 0.2]
               )
    end
  end

  describe "the failure surface survives a long failure reason" do
    test "a reason far longer than the old varchar(255) persists and is readable",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      article = fixture(:article, %{tenant_id: t.id})
      batch_id = Ecto.UUID.generate()

      {:ok, entry} =
        manual(fn -> Custody.record(Scope.new(t.id), "article", article.id, :create) end)

      {1, _} =
        from(e in PostureEntry, where: e.id == ^entry.id)
        |> AdminRepo.update_all(set: [batch_id: batch_id])

      long = String.duplicate("x", 600)

      assert {1, _} = Custody.mark_batch_failed(t.id, batch_id, long)
      assert [failed] = Custody.list_failures(t.id)
      assert String.length(failed.failure_reason) == 500
    end

    test "the worker's reason is a stable CODE, never a raw driver term" do
      reason =
        Custody.failure_reason(
          %Postgrex.Error{postgres: %{message: "duplicate key value violates unique constraint"}},
          42
        )

      assert reason == "chain_append_database_error (correlation=42)"
      refute reason =~ "duplicate key"
    end
  end

  describe "the chain payload is redacted to the requested subject" do
    test "one row's claim does not enumerate the other rows in its batch", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      mine = fixture(:article, %{tenant_id: t.id})
      other = fixture(:article, %{tenant_id: t.id})

      manual(fn ->
        Custody.record_all(Scope.new(t.id), [
          {"article", mine.id, :create},
          {"article", other.id, :create}
        ])
      end)

      drain_custody()

      claim = claim!(t.id, "article", mine.id)
      assert [chain_entry] = claim.chain_entries

      subject_ids = Enum.map(chain_entry.payload["entries"], & &1["subject_id"])
      assert subject_ids == [mine.id]
      assert chain_entry.redacted_entry_count == 1
      # The leaf hash is still returned, so the claim still binds to the inclusion
      # proof; only the OTHER subjects' plaintext entries are withheld.
      assert is_binary(chain_entry.entry_hash)
    end
  end

  describe "record_all is batched" do
    test "N subjects are assigned in one pass, with contiguous per-row sequences",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      articles = for _ <- 1..5, do: fixture(:article, %{tenant_id: t.id})
      subjects = Enum.map(articles, &{"article", &1.id, :embed})

      results = manual(fn -> Custody.record_all(Scope.new(t.id), subjects) end)

      assert length(results) == 5
      assert Enum.all?(results, &match?({:ok, %PostureEntry{operation_sequence: 0}}, &1))

      # A second pass hands each row its OWN next number — never a shared one.
      results2 = manual(fn -> Custody.record_all(Scope.new(t.id), subjects) end)
      assert Enum.all?(results2, &match?({:ok, %PostureEntry{operation_sequence: 1}}, &1))
    end

    test "an invalid subject_type in a batch does not consume a sequence for it",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      article = fixture(:article, %{tenant_id: t.id})
      bogus = Ecto.UUID.generate()

      assert [{:ok, %PostureEntry{}}, {:error, :invalid_subject_type}] =
               manual(fn ->
                 Custody.record_all(Scope.new(t.id), [
                   {"article", article.id, :create},
                   {"story", bogus, :create}
                 ])
               end)

      assert Custody.highest_assigned_sequence(t.id, "story", bogus) == nil
    end
  end

  describe "the stale-pending sweeper" do
    test "enqueues a flush for a tenant whose enqueue was lost", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      article = fixture(:article, %{tenant_id: t.id})

      {:ok, entry} =
        manual(fn -> Custody.record(Scope.new(t.id), "article", article.id, :create) end)

      # Simulate "committed pending, nothing scheduled": age the row past the stale
      # window and drop every scheduled flush.
      stale = DateTime.add(DateTime.utc_now(), -(Custody.stale_pending_seconds() + 60), :second)

      {1, _} =
        from(e in PostureEntry, where: e.id == ^entry.id)
        |> AdminRepo.update_all(set: [updated_at: stale])

      assert [_stranded] = Custody.list_stale_pending(t.id)
      assert Custody.enqueue_stale_flushes() >= 1

      # The sweep's flush is the ORDINARY per-tenant flush, so the row lands in the
      # chain instead of reading `claim_pending` forever.
      drain_custody()
      assert Custody.list_stale_pending(t.id) == []
    end
  end

  describe "claim/3 refuses a malformed subject id" do
    test "a non-UUID subject id is an error, never a 500", %{tenant: t} do
      assert {:error, :invalid_subject_id} = Custody.claim(t.id, "article", "not-a-uuid")
      assert {:error, :invalid_subject_type} = Custody.claim(t.id, "story", Ecto.UUID.generate())
    end
  end
end
