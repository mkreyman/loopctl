defmodule Loopctl.Workers.MemoryPromotionWorkerTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Workers.MemoryPromotionWorker

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_turns(scope, session_id, contents) do
    Enum.each(contents, fn content ->
      fixture(:session_memory,
        tenant_id: scope.tenant_id,
        subject_id: scope.subject_id,
        session_id: session_id,
        role: :user,
        content: content
      )
    end)
  end

  defp candidate_json(candidates) do
    candidates
    |> Enum.map(fn c ->
      %{
        "text" => c.text,
        "when_to_apply" => Map.get(c, :when_to_apply, "when relevant"),
        "tags" => Map.get(c, :tags, ["t"]),
        "confidence" => c.confidence,
        "cross_links" => Map.get(c, :cross_links, [])
      }
    end)
    |> JSON.encode!()
  end

  # Stub the LLM to send a message on every call (so a re-run's skip is observable)
  # and return the crafted candidates.
  defp stub_llm(candidates) do
    json = candidate_json(candidates)

    stub(Loopctl.MockPromoterLLM, :extract, fn _tenant_id, _content, _opts ->
      send(self(), :llm_called)
      {:ok, json}
    end)
  end

  # A 1536-dim unit vector keyed on `seed` — distinct seeds are orthogonal (cosine
  # score 0, not near-dup), identical seeds are identical (score 1.0, near-dup).
  # A 16-hot 1536-dim vector keyed on the full seed term. Two seeds collide only if
  # all sixteen independent hashes collide (negligible), so distinct seeds are
  # near-orthogonal and equal seeds are identical (distance 0) — exactly what the
  # near-dup assertions need.
  defp unit_vec(seed) do
    hot = for salt <- 0..15, into: MapSet.new(), do: rem(:erlang.phash2({seed, salt}), 1536)
    Enum.map(0..1535, fn i -> if MapSet.member?(hot, i), do: 1.0, else: 0.0 end)
  end

  # Fold `tenant_id` into the embedding seed so THIS test's vectors live in their
  # own well-separated region of the globally-shared pgvector HNSW index. Without
  # this the text-only seed puts every tenant's "shared" near-dup at the SAME
  # index point, where other tenants' concurrent rows crowd it and the ef_search
  # graph walk non-deterministically misses the exact match under full-suite load
  # (issue #421). Per-tenant seeding preserves the WITHIN-test geometry (equal
  # text_to_seed → identical vector → near-dup; distinct → near-orthogonal) while
  # isolating it across tenants, so near-dup recall is deterministic.
  defp stub_embeddings(text_to_seed) do
    stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, text ->
      tenant_id = EgressScope.coerce(scope).tenant_id
      {:ok, unit_vec({tenant_id, text_to_seed.(text)})}
    end)
  end

  defp run(scope, session_id) do
    MemoryPromotionWorker.perform(%Oban.Job{
      args: %{
        "tenant_id" => scope.tenant_id,
        "subject_id" => scope.subject_id,
        "project_id" => scope.project_id,
        "session_id" => session_id
      }
    })
  end

  defp all_promoted(scope) do
    from(m in MemorySchema,
      where:
        m.tenant_id == ^scope.tenant_id and m.subject_id == ^scope.subject_id and
          m.source == :promoted
    )
    |> AdminRepo.all()
  end

  defp watermark(scope, session_id), do: Memory.get_session_promotion(scope, session_id)

  # `tenant_id` filters to the calling test's tenant — telemetry handlers are GLOBAL, so
  # without it a concurrent async test's event of the same name would leak in.
  defp attach_telemetry(events, tenant_id \\ nil) do
    handler = "test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      Enum.map(events, &[:loopctl, :memory_promotion, &1]),
      fn name, meas, meta, _ ->
        if is_nil(tenant_id) or meta[:tenant_id] == tenant_id do
          send(test_pid, {:telemetry, List.last(name), meas, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.1 — writes promoted memories + watermark
  # ---------------------------------------------------------------------------

  describe "perform/1 — promotes candidates (TC-29.2.1)" do
    test "writes gated candidates as :promoted with source_session_id/confidence/hash + watermark" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      seed_turns(scope, "s1", ["decision one made", "decision two made"])

      stub_llm([
        %{text: "prefer expedited reship", confidence: 0.9, tags: ["ship"]},
        %{text: "email beats phone for this customer", confidence: 0.8, tags: ["comm"]}
      ])

      assert :ok = run(scope, "s1")

      rows = all_promoted(scope)
      assert length(rows) == 2

      Enum.each(rows, fn m ->
        assert m.source == :promoted
        assert m.source_session_id == "s1"
        assert is_float(m.confidence)
        assert is_binary(m.embedding_content_hash)
        # The synchronous write-time hash matches the schema's canonical hash.
        assert m.embedding_content_hash == MemorySchema.embedding_content_hash(m.text)
      end)

      wm = watermark(scope, "s1")
      assert wm.session_content_hash != nil
      assert wm.promoted_at != nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.2 — watermark skip (unchanged + zero-survivor)
  # ---------------------------------------------------------------------------

  describe "perform/1 — watermark idempotency (TC-29.2.2)" do
    test "an unchanged session is not re-compiled on re-run (no LLM call)" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      seed_turns(scope, "s1", ["fact a stated", "fact b stated"])
      stub_llm([%{text: "durable fact a", confidence: 0.9}])

      assert :ok = run(scope, "s1")
      assert_received :llm_called
      assert length(all_promoted(scope)) == 1

      # Re-run with identical content: watermark match → skipped, LLM NOT called.
      assert :ok = run(scope, "s1")
      refute_received :llm_called
      assert length(all_promoted(scope)) == 1
    end

    test "a zero-survivor session is still watermarked and then skipped" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      seed_turns(scope, "s1", ["chatter one", "chatter two"])
      # All candidates below the 0.5 threshold → compile returns [].
      stub_llm([%{text: "low signal", confidence: 0.1}])

      assert :ok = run(scope, "s1")
      assert_received :llm_called
      assert all_promoted(scope) == []
      assert watermark(scope, "s1") != nil

      assert :ok = run(scope, "s1")
      refute_received :llm_called
    end

    # US-29.3 finding fix (budget-starvation): a 0/1-turn session compiles to nothing
    # WITHOUT an LLM call, so it must NOT write a budget-consuming watermark. Otherwise
    # an agent POSTing N distinct junk/empty session_ids (each 0 turns) could exhaust
    # the tenant's per-hour promotion budget at zero LLM cost.
    test "a 0-turn (junk/empty) session is a no-op: no LLM call, no watermark, no budget spent" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      # Fail the test loudly if the LLM is ever reached for a 0-turn session.
      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o ->
        send(self(), :llm_called)
        {:ok, "[]"}
      end)

      before = Memory.promotion_compiles_this_hour(scope.tenant_id)

      assert :ok = run(scope, "junk-session-id")

      refute_received :llm_called
      assert watermark(scope, "junk-session-id") == nil
      assert all_promoted(scope) == []
      # The watermark meter did not advance — the tenant's budget is untouched.
      assert Memory.promotion_compiles_this_hour(scope.tenant_id) == before
    end

    test "a single-turn session is a no-op: no LLM call and no watermark" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      seed_turns(scope, "s1", ["only one turn — nothing durable to compile"])

      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o ->
        send(self(), :llm_called)
        {:ok, "[]"}
      end)

      assert :ok = run(scope, "s1")
      refute_received :llm_called
      assert watermark(scope, "s1") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.3 — paraphrase supersede
  # ---------------------------------------------------------------------------

  describe "perform/1 — near-dup supersede (TC-29.2.3)" do
    test "a changed session paraphrase supersedes rather than duplicating" do
      scope = fixture(:memory_scope, subject_id: "A")
      orig = "customer prefers async email updates"
      para = "this customer likes email updates asynchronously"
      # Map the original and its paraphrase to the SAME embedding (near-dup); every
      # other text is orthogonal.
      stub_embeddings(fn text -> if text in [orig, para], do: "shared", else: text end)

      seed_turns(scope, "s1", ["turn one", "turn two"])
      stub_llm([%{text: orig, confidence: 0.9}])
      assert :ok = run(scope, "s1")
      assert length(all_promoted(scope)) == 1

      # Change the session content (new hash) and emit the paraphrase.
      seed_turns(scope, "s1", ["turn three added"])
      stub_llm([%{text: para, confidence: 0.9}])
      assert :ok = run(scope, "s1")

      # Two rows total (incl. superseded); default list shows only the live one.
      all = all_promoted(scope)
      assert length(all) == 2
      live = Enum.filter(all, &is_nil(&1.superseded_by))
      superseded = Enum.reject(all, &is_nil(&1.superseded_by))
      assert length(live) == 1
      assert length(superseded) == 1
      assert hd(live).text == para
      assert hd(superseded).text == orig

      assert Memory.list(scope).meta.total_count == 1
      assert Memory.list(scope, include_superseded: true).meta.total_count == 2
    end

    test "re-running the same (changed) content is a watermark no-op — superseded count stable" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      seed_turns(scope, "s1", ["one", "two"])
      stub_llm([%{text: "fact", confidence: 0.9}])
      assert :ok = run(scope, "s1")

      before = length(all_promoted(scope))
      assert :ok = run(scope, "s1")
      assert length(all_promoted(scope)) == before
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.4 — exact dedupe / on-conflict (no double insert)
  # ---------------------------------------------------------------------------

  describe "persist_promotion/2 — exact dedupe (TC-29.2.4)" do
    test "persisting the same candidate twice yields exactly one promoted row" do
      scope = %{fixture(:memory_scope, subject_id: "A") | session_id: "s1"}
      stub_embeddings(& &1)

      candidates = [
        %{text: "exactly one row", when_to_apply: "", tags: [], confidence: 0.9, cross_links: []}
      ]

      assert {:ok, %{promoted: 1}} = Memory.persist_promotion(scope, candidates)
      assert {:ok, %{deduped: 1, promoted: 0}} = Memory.persist_promotion(scope, candidates)

      assert length(all_promoted(scope)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # AC-29.2.4 — promoted rows are embedded SYNCHRONOUSLY at write time, so a near-dup
  # written earlier is immediately recallable (no async-embedding lag window in which a
  # paraphrase could slip past `nearest_live/2` and duplicate). Under async prod this
  # gap was previously MASKED by the :inline test engine embedding synchronously.
  # ---------------------------------------------------------------------------

  describe "persist_promotion/2 — synchronous embedding (AC-29.2.4)" do
    test "a promoted row carries its embedding immediately (no async fill required)" do
      scope = %{fixture(:memory_scope, subject_id: "A") | session_id: "s1"}
      stub_embeddings(& &1)

      candidates = [
        %{text: "durable fact", when_to_apply: "", tags: [], confidence: 0.9, cross_links: []}
      ]

      assert {:ok, %{promoted: 1}} = Memory.persist_promotion(scope, candidates)

      [row] = all_promoted(scope)
      {:ok, with_embedding} = Memory.get_memory_for_embedding(scope.tenant_id, row.id)
      # The vector is present at write time — not left NULL for an async worker.
      refute is_nil(with_embedding.embedding)
    end

    test "two paraphrase candidates in ONE run supersede rather than both inserting fresh" do
      scope = %{fixture(:memory_scope, subject_id: "A") | session_id: "s1"}
      a = "customer prefers async email updates"
      b = "this customer likes email updates asynchronously"
      # Both paraphrases map to the SAME embedding (near-dup); different text ⇒ different
      # hash, so exact-dedupe cannot catch it — only a synchronously-embedded first row
      # makes the second candidate's near-dup recall find it within the same run.
      stub_embeddings(fn text -> if text in [a, b], do: "shared", else: text end)

      candidates = [
        %{text: a, when_to_apply: "", tags: [], confidence: 0.9, cross_links: []},
        %{text: b, when_to_apply: "", tags: [], confidence: 0.9, cross_links: []}
      ]

      assert {:ok, %{promoted: 1, superseded: 1}} = Memory.persist_promotion(scope, candidates)

      all = all_promoted(scope)
      assert length(all) == 2
      assert length(Enum.filter(all, &is_nil(&1.superseded_by))) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.5 — degraded embeddings → snooze, no duplicate
  # ---------------------------------------------------------------------------

  describe "perform/1 — degraded embeddings (TC-29.2.5)" do
    test "recall fallback snoozes the job without inserting a possible duplicate" do
      scope = fixture(:memory_scope, subject_id: "A")

      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :timeout}
      end)

      seed_turns(scope, "s1", ["one", "two"])
      stub_llm([%{text: "would-be fact", confidence: 0.9}])

      assert {:snooze, _} = run(scope, "s1")
      assert all_promoted(scope) == []
      # No watermark advance — a healthy retry can re-attempt.
      assert watermark(scope, "s1") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # US-37.5 — HeavyRead per-tenant gate shed on the promotion WRITE path
  # ---------------------------------------------------------------------------

  describe "perform/1 — HeavyRead gate shed (US-37.5)" do
    alias Loopctl.HeavyRead.TenantGate

    test "an over-cap near-dup recall SNOOZES loss-free (no attempt burned, no watermark, no rows)" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)

      seed_turns(scope, "s1", ["one", "two"])
      stub_llm([%{text: "would-be fact", confidence: 0.9}])

      # Saturate THIS (fresh, isolated) tenant's per-tenant HeavyRead in-flight budget so
      # the near-dup HNSW recall is SHED. Because `find_promoted_near_dup/2` passes
      # `on_overload: :tag`, the shed returns `{:error, :heavy_read_overloaded}` and
      # propagates to a loss-free `{:snooze, n}` — NOT a raised OverloadedError that would
      # burn an Oban attempt toward max_attempts on the write path.
      cap = TenantGate.cap()
      assert :ok = TenantGate.acquire(scope.tenant_id, cap, cap)
      on_exit(fn -> TenantGate.release(scope.tenant_id, cap) end)

      assert {:snooze, _} = run(scope, "s1")
      # Loss-free: nothing persisted and no watermark advance, so a later run (once the
      # tenant's heavy-read burst subsides) re-attempts the promotion.
      assert all_promoted(scope) == []
      assert watermark(scope, "s1") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.6 — scope isolation
  # ---------------------------------------------------------------------------

  describe "perform/1 — scope isolation (TC-29.2.6)" do
    test "promotion never crosses subject scope" do
      tenant = fixture(:tenant)
      scope_a = fixture(:memory_scope, tenant_id: tenant.id, subject_id: "A")
      scope_b = fixture(:memory_scope, tenant_id: tenant.id, subject_id: "B")
      stub_embeddings(& &1)

      seed_turns(scope_a, "s1", ["a-one", "a-two"])
      stub_llm([%{text: "subject A fact", confidence: 0.9}])
      assert :ok = run(scope_a, "s1")

      assert Enum.all?(all_promoted(scope_a), &(&1.subject_id == "A"))
      assert all_promoted(scope_b) == []
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.9 — subject at memory cap → terminal discard + telemetry
  # ---------------------------------------------------------------------------

  describe "perform/1 — quota terminal discard (TC-29.2.9)" do
    test "a subject at its memory cap discards terminally and records telemetry" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      attach_telemetry([:quota_exceeded])

      cap = Application.get_env(:loopctl, :max_long_term_memories_per_subject)

      for _ <- 1..cap do
        fixture(:memory, tenant_id: scope.tenant_id, subject_id: "A")
      end

      seed_turns(scope, "s1", ["one", "two"])
      stub_llm([%{text: "cannot fit", confidence: 0.9}])

      assert {:discard, :quota_exceeded} = run(scope, "s1")
      # The dropped-survivor count is emitted so the loss is VISIBLE, not silent: the
      # single compiled candidate could not be written, so dropped == 1.
      assert_received {:telemetry, :quota_exceeded, %{count: 1, dropped: 1}, %{tenant_id: _}}
      # Watermark advanced so the unchanged session is not re-compiled just to re-hit
      # the cap.
      assert watermark(scope, "s1") != nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC-29.2.9 / AC-29.2.11 — compile/LLM failure is retryable AND visible
  # ---------------------------------------------------------------------------

  describe "perform/1 — compile failure (AC-29.2.9 / AC-29.2.11)" do
    test "an LLM/compile error emits :failed telemetry, returns {:error,_}, and does NOT advance the watermark" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      attach_telemetry([:failed], scope.tenant_id)
      seed_turns(scope, "s1", ["one", "two"])

      # The BYO LLM key is bad / provider down.
      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o -> {:error, :provider_down} end)

      # {:error,_} → Oban retries with backoff (no {:ok}/{:discard} that would swallow it).
      assert {:error, :provider_down} = run(scope, "s1")
      # Visible in metrics, tagged with the failing stage.
      assert_received {:telemetry, :failed, %{count: 1}, %{stage: :compile}}
      # No watermark advance — a healthy retry re-attempts the same session.
      assert watermark(scope, "s1") == nil
      assert all_promoted(scope) == []
    end

    test "a compile failure at/above the attempt cap is TERMINALLY discarded (bounds LLM key spend)" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      seed_turns(scope, "s1", ["one", "two"])

      # A persistently-failing compile burns a BYO LLM call per attempt and is NOT counted
      # by the compiles/hour meter, so once the attempt count reaches the cap it must
      # discard rather than retry to max_attempts (AC-29.2.8).
      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o -> {:error, :provider_down} end)

      job = %Oban.Job{
        attempt: 2,
        args: %{
          "tenant_id" => scope.tenant_id,
          "subject_id" => scope.subject_id,
          "project_id" => scope.project_id,
          "session_id" => "s1"
        }
      }

      assert {:discard, {:compile_failed, :provider_down}} = MemoryPromotionWorker.perform(job)
      # Still no watermark advance / no rows — the session can re-promote if content changes.
      assert watermark(scope, "s1") == nil
      assert all_promoted(scope) == []
    end

    test "US-37.1 (AC-37.1.4): a node-local admission rate-limit SNOOZES loss-free — even AT the attempt cap (never discards)" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      attach_telemetry([:failed], scope.tenant_id)
      seed_turns(scope, "s1", ["one", "two"])

      # The provider admission gate is shut -> compile returns {:error, :rate_limited_local}.
      # This is loss-free backpressure, NOT a compile failure: it must snooze WITHOUT
      # routing through compile_failure_result/2 (which would terminally discard at the cap).
      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o -> {:error, :rate_limited_local} end)

      # Default attempt (0) snoozes.
      assert {:snooze, seconds} = run(scope, "s1")
      assert is_integer(seconds) and seconds > 0

      # AT/above the compile-attempt cap it STILL snoozes (the medium-finding regression:
      # rate-limited-local must never be discarded like a real compile failure would be).
      job_at_cap = %Oban.Job{
        attempt: 2,
        args: %{
          "tenant_id" => scope.tenant_id,
          "subject_id" => scope.subject_id,
          "project_id" => scope.project_id,
          "session_id" => "s1"
        }
      }

      assert {:snooze, _} = MemoryPromotionWorker.perform(job_at_cap)

      # Not counted/logged as a compile failure, and no watermark advance / no rows.
      refute_received {:telemetry, :failed, _, _}
      assert watermark(scope, "s1") == nil
      assert all_promoted(scope) == []
    end
  end

  # ---------------------------------------------------------------------------
  # AC-29.2.8 — execution-time per-tenant budget gate (closes the enqueue race)
  # ---------------------------------------------------------------------------

  describe "perform/1 — execution-time budget re-check (AC-29.2.8)" do
    test "a compile at the per-tenant compiles/hour budget is discarded WITHOUT an LLM call" do
      scope = fixture(:memory_scope, subject_id: "A")
      stub_embeddings(& &1)
      attach_telemetry([:budget_exceeded], scope.tenant_id)

      budget = Application.get_env(:loopctl, :memory_promotion_compiles_per_hour)

      # Fill this tenant's hourly budget with distinct promoted sessions.
      for i <- 1..budget do
        {:ok, _} =
          Memory.upsert_session_promotion(%{scope | session_id: "seed#{i}"}, %{
            content_hash: "h#{i}",
            last_turn_inserted_at: DateTime.utc_now()
          })
      end

      # Flag the LLM if it is (wrongly) called.
      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o ->
        send(self(), :llm_called)
        {:ok, "[]"}
      end)

      seed_turns(scope, "over", ["one", "two"])

      assert {:discard, :budget_exceeded} = run(scope, "over")
      refute_received :llm_called
      assert_received {:telemetry, :budget_exceeded, %{count: 1}, %{tenant_id: _}}
      assert all_promoted(scope) == []
      # No watermark advance — the next sweep re-enqueues once budget frees up.
      assert watermark(scope, "over") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC-29.2.4 — near-dup supersede NEVER clobbers an explicit user memory
  # ---------------------------------------------------------------------------

  describe "perform/1 — near-dup is source-scoped to :promoted (AC-29.2.4)" do
    test "a promoted candidate near an EXPLICIT memory inserts fresh; the explicit row stays live" do
      scope = fixture(:memory_scope, subject_id: "A")
      shared = "customer prefers async email updates"
      # The explicit memory and the promoted candidate share an embedding (near-dup);
      # every other text is orthogonal.
      stub_embeddings(fn text -> if text == shared, do: "shared", else: text end)

      # The user's own explicit long-term memory.
      {:ok, explicit} = Memory.remember(scope, %{tier: :long_term, text: shared})
      assert explicit.source == :explicit

      # Auto-promote a session whose sole survivor is a near-dup of the explicit memory.
      seed_turns(scope, "s1", ["turn one", "turn two"])
      stub_llm([%{text: shared, confidence: 0.9}])
      assert :ok = run(scope, "s1")

      # The unattended promoter did NOT supersede the human-authored memory: it stays
      # live, and a fresh :promoted row was inserted instead.
      reloaded = AdminRepo.get(MemorySchema, explicit.id)
      assert is_nil(reloaded.superseded_by)

      promoted = all_promoted(scope)
      assert length(promoted) == 1
      assert hd(promoted).source == :promoted
      assert is_nil(hd(promoted).superseded_by)
    end
  end
end
