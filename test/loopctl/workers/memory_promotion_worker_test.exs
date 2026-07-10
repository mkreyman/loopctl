defmodule Loopctl.Workers.MemoryPromotionWorkerTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
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
  defp unit_vec(seed) do
    idx = rem(:erlang.phash2(seed), 1536)
    Enum.map(0..1535, fn i -> if i == idx, do: 1.0, else: 0.0 end)
  end

  defp stub_embeddings(text_to_seed) do
    stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
      {:ok, unit_vec(text_to_seed.(text))}
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

  defp attach_telemetry(events) do
    handler = "test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      Enum.map(events, &[:loopctl, :memory_promotion, &1]),
      fn name, meas, meta, _ -> send(test_pid, {:telemetry, List.last(name), meas, meta}) end,
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
      assert_received {:telemetry, :quota_exceeded, _, %{tenant_id: _}}
      # Watermark advanced so the unchanged session is not re-compiled just to re-hit
      # the cap.
      assert watermark(scope, "s1") != nil
    end
  end
end
