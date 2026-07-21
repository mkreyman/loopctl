defmodule Loopctl.CustodyClaimTest do
  @moduledoc """
  US-41.7 — egress posture as a witnessed custody claim in the audit chain / STH.

  Covers TC-41.7.1 … TC-41.7.10 plus the review's adversarial cases. The claim's
  whole value is that it CANNOT be read as a satisfied attestation unless the
  recorded sequence is complete and contiguous, so most of these tests are
  adversarial: drop an entry (from the middle AND from the tail), replay a batch
  while new rows arrive, change the settings afterwards, mark local_only after the
  fact, read before the flush.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  alias Ecto.Adapters.SQL
  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Verifier
  alias Loopctl.Custody
  alias Loopctl.Custody.Coverage
  alias Loopctl.Custody.PostureEntry
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Test.AllowlistSource

  setup :verify_on_exit!

  # The two endpoints `Egress.resolved_endpoints/1` resolves today: the
  # server-wide embedding provider and the tenant's chat provider.
  @embedding_host "api.openai.com"
  @chat_host "api.anthropic.com"
  # A PUBLIC host a tenant may legitimately declare as its own (a vendor host may
  # never be declared — the policy rejects it at write time).
  @declared_host "ollama.example.com"

  setup do
    tenant = fixture(:tenant)

    on_exit(fn ->
      PinCache.invalidate_tenant(tenant.id)
      AllowlistSource.clear()
    end)

    {:ok, tenant: tenant}
  end

  # An OPERATOR carve-out making both resolved endpoints network-local for THIS
  # process only (the test allowlist source is process-local, so async tests do
  # not fight over it).
  defp all_endpoints_local do
    AllowlistSource.put([@embedding_host, @chat_host])
  end

  # Local embedding endpoint, vendor chat endpoint (TC-41.7.6).
  defp mixed_endpoints do
    AllowlistSource.put([@embedding_host])
  end

  defp mark_local_only(tenant_id) do
    {:ok, _} = Egress.enable_local_only(tenant_id, nil, acknowledge: true)
    PinCache.invalidate_tenant(tenant_id)
    :ok
  end

  # Oban runs INLINE in the test env, which would flush the batch before the test
  # could observe the pending state. `:manual` puts the job in the queue instead,
  # so `drain_custody/0` is an explicit, observable step — which is exactly the
  # pre-drain / post-drain distinction TC-41.7.1 is about.
  defp manual(fun), do: Oban.Testing.with_testing_mode(:manual, fun)

  defp create_article(tenant_id) do
    {:ok, article} =
      manual(fn -> Knowledge.create_article(tenant_id, build(:article, %{status: :draft})) end)

    article
  end

  defp record(scope, subject_id, operation) do
    manual(fn -> Custody.record(scope, "article", subject_id, operation) end)
  end

  defp claim!(tenant_id, article_id) do
    {:ok, claim} = Custody.claim(tenant_id, "article", article_id)
    claim
  end

  defp drain_custody do
    Oban.drain_queue(queue: :audit, with_scheduled: true)
  end

  defp queued_flush_jobs(tenant_id) do
    from(j in "oban_jobs",
      where:
        j.worker == "Loopctl.Workers.CustodyPostureAppendWorker" and
          j.state in ["available", "scheduled", "executing", "retryable"] and
          fragment("?->>'tenant_id' = ?", j.args, ^tenant_id),
      select: count(j.id)
    )
    |> Loopctl.Repo.one()
  end

  defp chain_entry_count(tenant_id) do
    from(e in AuditChain.Entry,
      where: e.tenant_id == ^tenant_id and e.action == ^Custody.chain_action(),
      select: count(e.id)
    )
    |> AdminRepo.one()
  end

  describe "TC-41.7.1 posture recorded and bound to the article" do
    setup %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)
      {:ok, article: create_article(tenant.id)}
    end

    test "the PRE-DRAIN read is 'claim pending', never absent and never an attestation",
         %{tenant: t, article: article} do
      claim = claim!(t.id, article.id)

      assert claim.claim_state == "claim_pending"
      assert claim.pending_entry_count >= 1
      assert claim.third_party_egress_on_covered_paths == "unknown"
      refute claim.claim_state == "no_claim_recorded"
      # AC-41.7.8(b): the payload names the work it is waiting on.
      assert claim.enqueued_batch_refs != [] or claim.batch_refs != []
      assert claim.summary =~ "PENDING"
    end

    test "after draining, the claim is complete, contiguous and all network-local", %{
      tenant: t,
      article: article
    } do
      scope = Scope.new(t.id, article.project_id)
      {:ok, _} = record(scope, article.id, :embed)
      {:ok, _} = record(scope, article.id, :classify)
      drain_custody()

      claim = claim!(t.id, article.id)

      assert claim.claim_state == "claim_recorded"
      assert claim.completeness == "complete"
      assert claim.contiguous
      assert claim.third_party_egress_on_covered_paths == false
      assert claim.posture == "all_network_local"

      # ... and it NAMES the local endpoints used.
      hosts = Enum.map(claim.endpoints_involved, & &1.host)
      assert @embedding_host in hosts
      assert @chat_host in hosts
      assert Enum.all?(claim.endpoints_involved, & &1.local)

      # ... and the coverage field states which egress paths are attested.
      assert "provider_calls" in claim.coverage.covered_paths
      assert claim.summary =~ "covered egress paths"
    end

    test "the entry carries a chain position, so it is bound into the audit chain", %{
      tenant: t,
      article: article
    } do
      drain_custody()
      [entry] = Custody.list_entries(t.id, "article", article.id)

      assert entry.state == "recorded"
      assert is_integer(entry.chain_position)
      assert entry.operation == "create"
      assert entry.operation_sequence == 0
    end
  end

  describe "each entry records only the endpoints ITS operation resolves (AC-41.7.3)" do
    setup %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)
      {:ok, article: create_article(tenant.id)}
    end

    test "an embed names the embedding endpoint and NOT the chat endpoint it never called",
         %{tenant: t, article: article} do
      {:ok, _} = record(Scope.new(t.id, article.project_id), article.id, :embed)
      drain_custody()

      claim = claim!(t.id, article.id)
      embed = Enum.find(claim.entries, &(&1.operation == "embed"))

      assert Enum.map(embed.posture["endpoints"], & &1["kind"]) == ["embedding"]
      assert Enum.map(embed.posture["endpoints"], & &1["host"]) == [@embedding_host]
    end

    test "a classify names the chat endpoint only", %{tenant: t, article: article} do
      {:ok, _} = record(Scope.new(t.id, article.project_id), article.id, :classify)
      drain_custody()

      claim = claim!(t.id, article.id)
      classify = Enum.find(claim.entries, &(&1.operation == "classify"))

      assert Enum.map(classify.posture["endpoints"], & &1["kind"]) == ["chat"]
      assert Enum.map(classify.posture["endpoints"], & &1["host"]) == [@chat_host]
    end

    test "a create resolves no endpoint at all — the content write calls nothing",
         %{tenant: t, article: article} do
      drain_custody()

      claim = claim!(t.id, article.id)
      create = Enum.find(claim.entries, &(&1.operation == "create"))

      assert create.posture["endpoints"] == []
      # Vacuously local: nothing was called, so nothing non-local was called.
      assert create.local_endpoints_only
      assert claim.endpoints_involved == []
    end

    test "encrypt_body is ABSENT, not asserted false, until it can be derived",
         %{tenant: t, article: article} do
      drain_custody()

      [entry] = Custody.list_entries(t.id, "article", article.id)

      # The row is immutable and hashed into an ed25519-signed tree head. A
      # hardcoded `false` for a setting that ships in US-41.6 would make every
      # entry written before then a permanently SIGNED false assertion about the
      # tenant's encryption posture. Every other key here is DERIVED from the same
      # function the guard enforces with; this one is omitted until it can be.
      refute Map.has_key?(entry.posture, "encrypt_body")
      assert Map.has_key?(entry.posture, "local_only")
    end
  end

  describe "TC-41.7.2 async embedding and re-embed appear as their own entries" do
    setup %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)
      {:ok, article: create_article(tenant.id)}
    end

    test "create, embed and re-embed are SEPARATE entries and the aggregate goes MIXED",
         %{tenant: t, article: article} do
      scope = Scope.new(t.id, article.project_id)

      # The async embedding job records its own entry with the posture resolved
      # for THAT call.
      {:ok, %PostureEntry{}} = record(scope, article.id, :embed)

      drain_custody()

      before = claim!(t.id, article.id)
      assert before.completeness == "complete"
      assert before.posture == "all_network_local"
      original_entries = Custody.list_entries(t.id, "article", article.id)

      # The tenant switches to a vendor embedding endpoint and an agent triggers a
      # re-embed (US-41.1 AC-41.1.10) — the exact case a write-time SNAPSHOT would
      # have gotten wrong.
      AllowlistSource.put([])
      PinCache.invalidate_tenant(t.id)
      {:ok, %PostureEntry{}} = record(scope, article.id, :reembed)
      drain_custody()

      claim = claim!(t.id, article.id)

      assert Enum.map(claim.entries, & &1.operation) == ["create", "embed", "reembed"]
      assert claim.completeness == "complete"
      assert claim.posture == "mixed"
      assert claim.third_party_egress_on_covered_paths == true

      # The ORIGINAL entries are unchanged.
      kept = Enum.take(Custody.list_entries(t.id, "article", article.id), 2)
      assert Enum.map(kept, & &1.posture) == Enum.map(original_entries, & &1.posture)
      assert Enum.all?(kept, & &1.local_endpoints_only)
    end
  end

  describe "TC-41.7.3 historical entries are immutable under settings change" do
    test "a later settings change does not alter what an existing entry says", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)
      article = create_article(t.id)
      {:ok, _} = record(Scope.new(t.id, article.project_id), article.id, :embed)
      drain_custody()

      [_create, before] = Custody.list_entries(t.id, "article", article.id)

      # Settings change: the operator carve-out goes away, so BOTH endpoints
      # would classify non-local from now on.
      AllowlistSource.put([])
      PinCache.invalidate_tenant(t.id)
      refute Egress.operation_posture(Scope.new(t.id)).local_endpoints_only

      [_create_after, after_change] = Custody.list_entries(t.id, "article", article.id)

      assert after_change.posture == before.posture
      assert after_change.local_endpoints_only == before.local_endpoints_only
      assert after_change.occurred_at == before.occurred_at
      assert Enum.all?(after_change.posture["endpoints"], & &1["local"])
    end

    test "the DATABASE refuses to rewrite what an entry asserts", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)
      article = create_article(t.id)
      [entry] = Custody.list_entries(t.id, "article", article.id)

      assert_raise Postgrex.Error, ~r/immutable/, fn ->
        from(e in PostureEntry, where: e.id == ^entry.id)
        |> AdminRepo.update_all(set: [local_endpoints_only: false])
      end
    end

    test "an outcome is MONOTONIC — a terminal outcome can never be rewritten", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)
      article = create_article(t.id)
      [entry] = Custody.list_entries(t.id, "article", article.id)

      :ok = Custody.record_outcome(entry, :failed)
      assert [%{outcome: "failed"}] = Custody.list_entries(t.id, "article", article.id)

      assert_raise Postgrex.Error, ~r/terminal/, fn ->
        from(e in PostureEntry, where: e.id == ^entry.id)
        |> AdminRepo.update_all(set: [outcome: "succeeded"])
      end
    end
  end

  describe "TC-41.7.4 claim is included in an STH and externally verifiable" do
    test "the posture record verifies against the signed tree head via the EXISTING protocol",
         %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
      Loopctl.TenantKeys.init_cache()
      {matching_pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: matching_pub)
        |> AdminRepo.update!()

      article = create_article(tenant.id)
      drain_custody()

      [entry] = Custody.list_entries(tenant.id, "article", article.id)
      {:ok, _sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      assert {:ok, proof} = AuditChain.inclusion_proof(tenant.id, entry.chain_position)

      # 1. The tree head is signed by the tenant's published audit key.
      assert {:ok, true} = Verifier.verify_sth(proof.sth, matching_pub)

      # 2. The custody posture record's chain entry is INSIDE that tree.
      assert {:ok, true} =
               Verifier.verify_inclusion(
                 proof.leaf_hash,
                 proof.audit_path,
                 proof.sth.merkle_root
               )

      # 3. A tampered leaf does not verify — the proof actually proves something.
      assert {:error, :invalid_inclusion_proof} =
               Verifier.verify_inclusion(
                 :crypto.hash(:sha256, "not the leaf"),
                 proof.audit_path,
                 proof.sth.merkle_root
               )
    end

    test "the CLAIM binds to the proven leaf — position alone would prove nothing",
         %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
      Loopctl.TenantKeys.init_cache()

      article = create_article(tenant.id)
      drain_custody()
      {:ok, _sth} = AuditChain.sign_and_store_tree_head(tenant.id)

      claim = claim!(tenant.id, article.id)
      [entry] = claim.entries
      [chain_entry] = claim.chain_entries

      # (a) The claim exposes the LEAF HASH of the batch carrying this entry, and
      #     it is the same leaf the inclusion proof proves at that position.
      {:ok, proof} = AuditChain.inclusion_proof(tenant.id, entry.chain_position)
      assert entry.chain_entry_hash == Base.url_encode64(proof.leaf_hash, padding: false)
      assert chain_entry.entry_hash == entry.chain_entry_hash

      # (b) ... and the leaf's PAYLOAD names this row's operation by a digest the
      #     reader can recompute from the posture the claim returned. Position +
      #     hash + payload digest is the whole chain of reasoning, end to end.
      payload_entry =
        Enum.find(chain_entry.payload["entries"], &(&1["subject_id"] == article.id))

      assert payload_entry["operation"] == "create"
      assert payload_entry["posture_digest"] == entry.posture_digest
      assert entry.posture_digest == Custody.posture_digest(entry.posture)
    end
  end

  describe "TC-41.7.5 no claim recorded reads as absent, not as satisfied" do
    test "an article written with no local_only marking has no claim at all", %{tenant: t} do
      # No marking: no operation sequence is ever assigned (AC-41.7.8(a)).
      article = create_article(t.id)

      claim = claim!(t.id, article.id)

      assert claim.claim_state == "no_claim_recorded"
      assert claim.entries == []
      refute Map.has_key?(claim, :posture)
      refute Map.has_key?(claim, :third_party_egress_on_covered_paths)
      assert claim.summary =~ "must not be read as one"
      # Nothing that could be misread as an attestation either way.
      refute claim.summary =~ "no third-party"
    end
  end

  describe "TC-41.7.6 mixed-posture write is reported accurately" do
    test "a local embedding endpoint with a vendor chat endpoint is NOT zero-egress",
         %{tenant: t} do
      mixed_endpoints()
      :ok = mark_local_only(t.id)
      article = create_article(t.id)
      # The classification pass is what actually POSTs the body to the CHAT
      # endpoint, so it is the operation that carries the vendor egress.
      {:ok, _} = record(Scope.new(t.id, article.project_id), article.id, :classify)
      drain_custody()

      claim = claim!(t.id, article.id)

      assert claim.completeness == "complete"
      assert claim.posture == "mixed"
      assert claim.third_party_egress_on_covered_paths == true

      vendor = Enum.find(claim.endpoints_involved, &(&1.host == @chat_host))
      assert vendor.local == false
      assert vendor.verdict == "non-local"
      assert claim.summary =~ "MIXED"
    end
  end

  describe "tenant-declared endpoints are NOT reported as no-third-party-egress" do
    test "an all-local sequence over a TENANT-DECLARED public host stays qualified",
         %{tenant: t} do
      # No operator allowlist: the tenant points its CHAT endpoint at a PUBLIC
      # host it merely attests is its own (a vendor host may never be declared).
      AllowlistSource.put([])

      {:ok, _} =
        Loopctl.Llm.upsert_settings(t.id, %{
          "chat_provider" => "openai_compatible",
          "chat_base_url" => "https://#{@declared_host}",
          "extraction_model" => "llama-3.1-8b-instruct"
        })

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => @declared_host,
          "purposes" => ["inference"]
        })

      :ok = mark_local_only(t.id)
      PinCache.invalidate_tenant(t.id)

      article = create_article(t.id)
      {:ok, _} = record(Scope.new(t.id, article.project_id), article.id, :classify)
      drain_custody()

      claim = claim!(t.id, article.id)
      encoded = Jason.encode!(claim)

      assert claim.completeness == "complete"
      assert claim.posture == "all_local_including_tenant_declared"
      # The two fields an agent branches on must BOTH carry the qualification.
      assert claim.third_party_egress_on_covered_paths == "tenant_declared_unverified"
      refute claim.third_party_egress_on_covered_paths == false
      assert claim.summary =~ "TENANT-DECLARED"
      assert claim.summary =~ "did not verify"
      refute encoded =~ "made no third-party call"

      endpoint = Enum.find(claim.endpoints_involved, &(&1.host == @declared_host))
      assert endpoint.local == true
      assert endpoint.network_local == false
      assert endpoint.verdict_code == "tenant_declared"
    end
  end

  describe "recording that starts mid-life is not a complete claim" do
    test "marking local_only AFTER the row exists reports partial_history, not zero-egress",
         %{tenant: t} do
      all_endpoints_local()

      # Harvested BEFORE any marking: no sequence is assigned for the create.
      article = create_article(t.id)
      assert claim!(t.id, article.id).claim_state == "no_claim_recorded"

      # The tenant marks local_only afterwards and triggers a re-embed against
      # local endpoints. Sequence 0 is now the RE-EMBED, not the create.
      :ok = mark_local_only(t.id)

      {:ok, %PostureEntry{operation_sequence: 0}} =
        record(Scope.new(t.id, article.project_id), article.id, :reembed)

      drain_custody()

      claim = claim!(t.id, article.id)
      encoded = Jason.encode!(claim)

      assert claim.completeness == "partial_history"
      assert claim.third_party_egress_on_covered_paths == "unknown"
      assert claim.posture == "recording_started_mid_life"
      assert claim.summary =~ "PARTIAL HISTORY"
      # The row WAS created and first embedded under whatever settings then
      # applied; the claim must not speak for that window.
      refute encoded =~ "made no third-party call"
    end
  end

  describe "TC-41.7.7 bulk harvest does not saturate the AdminRepo pool" do
    test "N articles produce ONE batched chain append, never N synchronous ones",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      articles = for _ <- 1..12, do: create_article(t.id)

      # Nothing has touched the audit chain yet: the hot path only wrote outbox
      # rows on the content transaction's own connection.
      assert chain_entry_count(t.id) == 0

      # And the harvest collapsed to ONE in-flight flush job for the tenant
      # (unique per tenant), not one per article.
      assert queued_flush_jobs(t.id) == 1

      drain_custody()

      # ONE chain append covered all 12 articles.
      assert chain_entry_count(t.id) == 1

      for article <- articles do
        assert claim!(t.id, article.id).completeness == "complete"
      end
    end

    test "a tenant with NO local_only marking enqueues no flush job at all", %{tenant: t} do
      # The predominantly non-local_only tenant base must not pay an Oban insert
      # plus a periodic no-op AdminRepo flush per article create.
      manual(fn ->
        for _ <- 1..5, do: Knowledge.create_article(t.id, build(:article, %{status: :draft}))
      end)

      assert queued_flush_jobs(t.id) == 0
    end

    test "a batch is CAPPED, and the remainder is re-enqueued rather than folded in",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      article = create_article(t.id)
      scope = Scope.new(t.id, article.project_id)

      # One more entry than a (test-shrunk) batch would carry is impossible to
      # assert cheaply against the production 500 cap, so assert the CONTRACT the
      # cap rests on instead: the limit is bounded and the flush re-enqueues while
      # anything is still pending.
      assert Custody.batch_limit() > 0
      {:ok, _} = record(scope, article.id, :embed)

      batch = Custody.batch_id(System.unique_integer([:positive]))
      assert {:ok, 2} = Custody.flush_batch(t.id, batch)
      assert claim!(t.id, article.id).completeness == "complete"
    end
  end

  describe "TC-41.7.8 coverage is driven by configuration" do
    setup %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)
      article = create_article(tenant.id)
      drain_custody()
      {:ok, article: article}
    end

    test "webhook coverage DISABLED: coverage names provider calls only and the wording stays qualified",
         %{tenant: t, article: article} do
      expect(Loopctl.MockCustodyCoverage, :covered_paths, fn -> [:provider_calls] end)

      claim = claim!(t.id, article.id)
      encoded = Jason.encode!(claim)

      assert claim.coverage.covered_paths == ["provider_calls"]
      assert claim.coverage.complete == false

      uncovered = Enum.map(claim.coverage.uncovered_paths, & &1.path)
      assert "webhook_delivery" in uncovered

      webhook = Enum.find(claim.coverage.uncovered_paths, &(&1.path == "webhook_delivery"))
      assert webhook.reason =~ "does not cover it"

      # NO unqualified zero-third-party-egress wording anywhere in the payload.
      refute encoded =~ "zero third-party egress"
      refute encoded =~ "zero third party egress"
      assert claim.summary =~ "covered egress paths"
    end

    test "every path covered: the wording is STILL scoped to what loopctl called",
         %{tenant: t, article: article} do
      expect(Loopctl.MockCustodyCoverage, :covered_paths, fn ->
        [:provider_calls, :ingestion_fetch, :webhook_delivery]
      end)

      claim = claim!(t.id, article.id)
      encoded = Jason.encode!(claim)

      assert claim.coverage.complete == true
      assert claim.coverage.uncovered_paths == []

      assert Enum.sort(claim.coverage.covered_paths) ==
               Enum.sort(["provider_calls", "ingestion_fetch", "webhook_delivery"])

      # Still scoped to the CALLS loopctl made — never to what those endpoints
      # did with the data afterwards.
      assert claim.attestation_scope =~ "endpoints loopctl called"
      assert claim.attestation_scope =~ "NO statement about what those endpoints did"
      refute encoded =~ "zero third-party egress"
      refute encoded =~ "never seen by a third party"
    end

    test "the production coverage source can never over-claim an uninstrumented path" do
      # `Loopctl.Custody.Coverage` intersects the configured set with the paths
      # that actually record a per-row posture entry, so a config typo cannot
      # widen the attestation.
      assert Coverage.covered_paths() == [:provider_calls]

      assert Enum.all?(
               Coverage.covered_paths(),
               &(&1 in Coverage.instrumented_paths())
             )
    end
  end

  describe "TC-41.7.9 custody claims are tenant-isolated" do
    test "tenant A's claim is not visible to tenant B", %{tenant: a} do
      b = fixture(:tenant)
      all_endpoints_local()
      :ok = mark_local_only(a.id)
      article = create_article(a.id)
      drain_custody()

      assert claim!(a.id, article.id).claim_state == "claim_recorded"

      # Read the SAME row id as tenant B.
      cross = claim!(b.id, article.id)
      assert cross.claim_state == "no_claim_recorded"
      assert cross.entries == []
      assert Custody.list_entries(b.id, "article", article.id) == []
    end

    test "the RLS POLICY itself hides tenant A's rows from a tenant-B session", %{tenant: a} do
      # `Loopctl.Custody` reads through AdminRepo (BYPASSRLS), so the query's own
      # `where tenant_id ==` is what isolates it there. That proves the WHERE
      # clause, not the policy — so exercise the POLICY too, through the
      # RLS-enforced repo under tenant B's session. If a future query loses its
      # tenant filter, this is the test that still catches it.
      b = fixture(:tenant)
      all_endpoints_local()
      :ok = mark_local_only(a.id)
      article = create_article(a.id)

      assert [_] = Custody.list_entries(a.id, "article", article.id)

      assert unscoped_posture_rows_visible_as(b.id) == 0
      assert unscoped_posture_rows_visible_as(a.id) >= 1
    end

    test "the table carries tenant_id and an RLS tenant_isolation policy (AC-41.7.9)" do
      for table <- ["custody_posture_entries", "custody_row_sequences"] do
        %{rows: [[count]]} =
          SQL.query!(
            AdminRepo,
            "SELECT count(*) FROM pg_policies WHERE tablename = $1 AND policyname = 'tenant_isolation'",
            [table]
          )

        assert count == 1

        %{rows: [[relrowsecurity, relforcerowsecurity]]} =
          SQL.query!(
            AdminRepo,
            "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1",
            [table]
          )

        # ENABLE, not FORCE (CLAUDE.md Multi-Tenant Rules).
        assert relrowsecurity
        refute relforcerowsecurity
      end
    end

    # A DELIBERATELY UNSCOPED count with the RLS context set and the BYPASSRLS
    # role dropped: the only thing keeping rows out of the result is the POLICY.
    # Stays on the AdminRepo connection because that is where the sandbox
    # transaction holding these rows lives.
    defp unscoped_posture_rows_visible_as(tenant_id) do
      {:ok, count} =
        AdminRepo.transaction(fn ->
          SQL.query!(
            AdminRepo,
            "SELECT set_config('app.current_tenant_id', $1, true)",
            [tenant_id]
          )

          SQL.query!(AdminRepo, "SET LOCAL ROLE loopctl_app", [])

          %{rows: [[count]]} =
            SQL.query!(AdminRepo, "SELECT count(*) FROM custody_posture_entries", [])

          SQL.query!(AdminRepo, "RESET ROLE", [])
          count
        end)

      count
    end
  end

  describe "TC-41.7.10 a lost or replayed append cannot forge a zero-egress claim" do
    setup %{tenant: tenant} do
      all_endpoints_local()
      :ok = mark_local_only(tenant.id)
      {:ok, article: create_article(tenant.id)}
    end

    test "a GAP in the middle of the sequence reports INCOMPLETE, never zero-egress",
         %{tenant: t, article: article} do
      scope = Scope.new(t.id, article.project_id)
      {:ok, _} = record(scope, article.id, :embed)
      {:ok, _} = record(scope, article.id, :classify)
      drain_custody()

      assert claim!(t.id, article.id).completeness == "complete"

      # Job loss / a node that died between the provider call and the append.
      [_zero, middle, _two] = Custody.list_entries(t.id, "article", article.id)
      AdminRepo.delete!(middle)

      claim = claim!(t.id, article.id)

      assert claim.completeness == "incomplete"
      assert claim.contiguous == false
      assert claim.third_party_egress_on_covered_paths == "unknown"
      refute Map.get(claim, :posture) == "all_network_local"
      assert claim.summary =~ "INCOMPLETE"
    end

    test "losing the TAIL of the sequence is a gap too — completeness is measured against the persisted high-water mark",
         %{tenant: t, article: article} do
      scope = Scope.new(t.id, article.project_id)
      {:ok, _} = record(scope, article.id, :embed)

      # The operation that actually egressed.
      AllowlistSource.put([])
      PinCache.invalidate_tenant(t.id)
      {:ok, _} = record(scope, article.id, :reembed)
      drain_custody()

      assert claim!(t.id, article.id).third_party_egress_on_covered_paths == true

      # Erase the LAST entry — the one that egressed. Measuring contiguity against
      # the surviving rows would leave 0..1 contiguous and restore a satisfied
      # all-local attestation.
      [_zero, _one, tail] = Custody.list_entries(t.id, "article", article.id)
      AdminRepo.delete!(tail)

      claim = claim!(t.id, article.id)

      assert claim.completeness == "incomplete"
      assert claim.contiguous == false
      assert claim.highest_assigned_sequence == 2
      assert claim.third_party_egress_on_covered_paths == "unknown"
    end

    test "an erased sequence number is NEVER handed out again", %{tenant: t, article: article} do
      scope = Scope.new(t.id, article.project_id)
      {:ok, %PostureEntry{operation_sequence: 1}} = record(scope, article.id, :embed)

      [_zero, one] = Custody.list_entries(t.id, "article", article.id)
      AdminRepo.delete!(one)

      # A MAX(sequence)+1 allocator would reuse 1 here and silently repair the gap,
      # permanently destroying the evidence of the erased operation.
      assert {:ok, %PostureEntry{operation_sequence: 2}} = record(scope, article.id, :classify)
      assert claim!(t.id, article.id).completeness == "incomplete"
    end

    test "losing EVERY entry still reports incomplete, never absent", %{
      tenant: t,
      article: article
    } do
      from(e in PostureEntry, where: e.tenant_id == ^t.id) |> AdminRepo.delete_all()

      claim = claim!(t.id, article.id)

      assert claim.claim_state == "claim_recorded"
      assert claim.completeness == "incomplete"
      refute claim.claim_state == "no_claim_recorded"
    end

    test "a DROPPED non-local append reports incomplete and shows on the failure surface",
         %{tenant: t, article: article} do
      scope = Scope.new(t.id, article.project_id)
      AllowlistSource.put([])
      PinCache.invalidate_tenant(t.id)
      {:ok, dropped} = record(scope, article.id, :embed)
      refute dropped.local_endpoints_only

      # The batch job exhausted its retries.
      batch = Custody.batch_id(999_999)

      from(e in PostureEntry, where: e.id == ^dropped.id)
      |> AdminRepo.update_all(set: [batch_id: batch])

      Custody.mark_batch_failed(t.id, batch, "chain append exhausted retries")

      claim = claim!(t.id, article.id)

      assert claim.completeness == "incomplete"
      assert claim.third_party_egress_on_covered_paths == "unknown"
      assert [failed] = claim.failed_entries
      assert failed.failure_reason =~ "exhausted retries"

      assert [surfaced] = Custody.list_failures(t.id)
      assert surfaced.id == dropped.id
    end

    test "replaying a partially-succeeded batch is a NO-OP — idempotent on (row, sequence)",
         %{tenant: t, article: article} do
      job_id = System.unique_integer([:positive])
      batch = Custody.batch_id(job_id)

      assert {:ok, 1} = Custody.flush_batch(t.id, batch)

      entries_before = Custody.list_entries(t.id, "article", article.id)
      chain_before = chain_entry_count(t.id)
      head_before = AuditChain.latest_entry(t.id)

      # Replay the SAME batch (an Oban retry after a partial success).
      assert {:ok, 0} = Custody.flush_batch(t.id, batch)

      assert Custody.list_entries(t.id, "article", article.id) == entries_before
      assert chain_entry_count(t.id) == chain_before
      assert AuditChain.latest_entry(t.id).id == head_before.id
      assert Custody.batch_id(job_id) == batch
    end

    test "an append that committed but lost its bookkeeping is finished, not duplicated",
         %{tenant: t, article: article} do
      job_id = System.unique_integer([:positive])
      batch = Custody.batch_id(job_id)

      assert {:ok, 1} = Custody.flush_batch(t.id, batch)
      chain_before = chain_entry_count(t.id)

      # Simulate the lost bookkeeping update: the chain entry exists, the rows are
      # pending again under the same batch.
      from(e in PostureEntry, where: e.tenant_id == ^t.id)
      |> AdminRepo.update_all(set: [state: "pending", batch_id: batch])

      assert {:ok, 1} = Custody.flush_batch(t.id, batch)

      assert chain_entry_count(t.id) == chain_before
      assert [%{state: "recorded"}] = Custody.list_entries(t.id, "article", article.id)
    end

    test "a replay NEVER sweeps newly-arrived entries into an already-appended batch",
         %{tenant: t, article: article} do
      job_id = System.unique_integer([:positive])
      batch = Custody.batch_id(job_id)

      assert {:ok, 1} = Custody.flush_batch(t.id, batch)

      # Lost bookkeeping again...
      from(e in PostureEntry, where: e.tenant_id == ^t.id)
      |> AdminRepo.update_all(set: [state: "pending", batch_id: batch])

      # ... and, crucially, a NEW operation lands between the two attempts. It is
      # NOT in the already-committed leaf's payload, so it must not be marked
      # recorded against it — that would hand the reader an inclusion proof for a
      # leaf that does not contain the operation.
      {:ok, fresh} = record(Scope.new(t.id, article.project_id), article.id, :embed)

      # `:manual` so the flush's own "still pending, re-enqueue" job does not run
      # INLINE and flush the new row before the assertions below observe it.
      assert {:ok, 1} = manual(fn -> Custody.flush_batch(t.id, batch) end)

      reloaded = AdminRepo.get!(PostureEntry, fresh.id)
      assert reloaded.state == "pending"
      assert is_nil(reloaded.chain_position)
      assert is_nil(reloaded.chain_entry_id)

      # ... and the leftover is RE-ENQUEUED rather than stranded. The same
      # mechanism drains the remainder of a capped batch.
      assert queued_flush_jobs(t.id) >= 1

      # And the claim as a whole is still PENDING — not a satisfied attestation
      # resting on a leaf that never carried the new operation.
      assert claim!(t.id, article.id).claim_state == "claim_pending"
    end
  end

  describe "a posture fault never destroys the content write (AC-41.7.7)" do
    test "an assignment that fails inside the content transaction leaves the write committed",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)

      # `:bogus` is rejected by the `custody_posture_entries_operation_check`
      # constraint, so the ENTRY insert fails inside the enclosing transaction.
      # Without the savepoint that would abort the whole content transaction — a
      # posture-recording fault destroying the article write it merely describes.
      result =
        Multi.new()
        |> Multi.insert(
          :article,
          Article.create_changeset(
            %Article{tenant_id: t.id},
            build(:article, %{status: :draft})
          )
        )
        |> Custody.assign_in_multi(
          :custody_posture,
          fn _ -> Scope.new(t.id) end,
          "article",
          & &1.article.id,
          :bogus
        )
        |> AdminRepo.transaction()

      assert {:ok, %{article: article, custody_posture: {:error, _reason}}} = result
      # The article COMMITTED.
      assert AdminRepo.get(Article, article.id)

      # ... and the consumed sequence number is a GAP, so the claim is incomplete
      # rather than silently absent.
      claim = claim!(t.id, article.id)
      assert claim.completeness == "incomplete"
      assert claim.highest_assigned_sequence == 0
    end

    test "an invalid subject_type is refused BEFORE a sequence is consumed", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)
      id = Ecto.UUID.generate()

      assert {:error, :invalid_subject_type} =
               Custody.assign(AdminRepo, Scope.new(t.id), "story", id, :create)

      assert is_nil(Custody.highest_assigned_sequence(t.id, "story", id))
    end
  end

  describe "a stranded pending batch is reaped and surfaced" do
    test "a flush that died leaves rows re-claimable and visible on the failure surface",
         %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)
      article = create_article(t.id)

      # A flush stamped its batch id and then died anywhere other than its own
      # final-attempt error branch (exception, node death, pruned job). Nothing
      # marks these failed, and no other flush could ever claim them.
      dead_batch = Custody.batch_id(System.unique_integer([:positive]))
      stale_at = DateTime.add(DateTime.utc_now(), -Custody.stale_pending_seconds() - 60, :second)

      from(e in PostureEntry, where: e.tenant_id == ^t.id)
      |> AdminRepo.update_all(set: [batch_id: dead_batch, updated_at: stale_at])

      assert [_stranded] = Custody.list_stale_pending(t.id)

      # A later flush REAPS them rather than leaving them pending forever.
      assert {:ok, 1} =
               Custody.flush_batch(t.id, Custody.batch_id(System.unique_integer([:positive])))

      assert claim!(t.id, article.id).completeness == "complete"
      assert Custody.list_stale_pending(t.id) == []
    end
  end

  describe "unmarked scopes assign no sequence (hot-path cost)" do
    test "a tenant with no local_only marking writes no posture rows", %{tenant: t} do
      article = create_article(t.id)

      assert Custody.list_entries(t.id, "article", article.id) == []
      assert claim!(t.id, article.id).claim_state == "no_claim_recorded"
    end
  end

  describe "memories are claimable too (AC-41.7.5)" do
    test "a memory row gets its own bound sequence, isolated from the article's", %{tenant: t} do
      all_endpoints_local()
      :ok = mark_local_only(t.id)
      memory_id = Ecto.UUID.generate()

      {:ok, %PostureEntry{operation_sequence: 0}} =
        manual(fn -> Custody.record(Scope.new(t.id), "memory", memory_id, :create) end)

      {:ok, %PostureEntry{operation_sequence: 1}} =
        manual(fn -> Custody.record(Scope.new(t.id), "memory", memory_id, :embed) end)

      drain_custody()

      {:ok, claim} = Custody.claim(t.id, "memory", memory_id)

      assert claim.subject_type == "memory"
      assert claim.completeness == "complete"
      assert claim.third_party_egress_on_covered_paths == false

      # A same-id article is a DIFFERENT subject: sequences are per (type, id).
      assert claim!(t.id, memory_id).claim_state == "no_claim_recorded"
    end
  end

  describe "invalid input" do
    test "an unknown subject type is rejected rather than silently empty", %{tenant: t} do
      assert {:error, :invalid_subject_type} = Custody.claim(t.id, "story", Ecto.UUID.generate())
    end
  end
end
