defmodule Loopctl.MemoryContextTest do
  @moduledoc """
  US-28.2 context API tests for `Loopctl.Memory` — remember / recall / forget /
  list / session_history / supersede.

  Async: all OLTP routes through `Loopctl.AdminRepo` (mirroring `Loopctl.Knowledge`)
  and `recall/2` routes through `Loopctl.HeavyRead` (which points at `AdminRepo` in
  test), so every path shares the one sandbox connection the fixtures insert
  through.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.Scope

  import Ecto.Query

  # --- TC-28.2.1: remember(:long_term) -> embed -> recall top-1 ---

  describe "remember/2 (:long_term) + recall/2" do
    test "recalls the embedded memory as top-1 with the pinned shape" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      {:ok, target} =
        Memory.remember(scope, %{tier: :long_term, text: "the sky is blue today"})

      # Inline Oban embeds it during remember/2 (embeddings queue, :inline in test).
      result = Memory.recall(scope, query: "sky", limit: 5)

      assert %{results: results, meta: meta} = result
      assert %{total_count: total, fallback: false, reason: nil} = meta
      assert total == length(results)
      assert [{top, score} | _] = results
      assert top.id == target.id
      assert is_float(score)

      # The persisted row carries a non-null embedding + content hash.
      {:ok, reloaded} = Memory.get_memory_for_embedding(scope.tenant_id, target.id)
      refute is_nil(reloaded.embedding)
      assert is_binary(reloaded.embedding_content_hash)
    end

    test "US-37.4 (AC-37.4.5): a just-written memory is embedded + recallable in the same run, never left NULL" do
      # The batch-embedding story (US-37.4) batches ONLY the bulk article-ingest path
      # and deliberately keeps the interactive `remember` path PER-RECORD/synchronous
      # (no coalescing drainer that could drop a just-written row). This guards that
      # invariant: a memory written now — and a SECOND one written immediately after,
      # as if a background ingest were already in flight — are BOTH embedded within
      # the run and immediately recallable, with non-null embeddings (no bounded
      # staleness, no wait for a periodic sweep).
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      {:ok, first} =
        Memory.remember(scope, %{tier: :long_term, text: "batch drainer in flight one"})

      {:ok, second} =
        Memory.remember(scope, %{tier: :long_term, text: "written during a drain two"})

      # Both rows carry a non-null embedding + content hash RIGHT AWAY.
      for id <- [first.id, second.id] do
        {:ok, reloaded} = Memory.get_memory_for_embedding(scope.tenant_id, id)
        refute is_nil(reloaded.embedding), "memory #{id} left embedding IS NULL"
        assert is_binary(reloaded.embedding_content_hash)
      end

      # And both are recallable (found, not []).
      recalled_ids =
        scope
        |> Memory.recall(query: "drain", limit: 10)
        |> Map.fetch!(:results)
        |> Enum.map(fn {m, _score} -> m.id end)

      assert first.id in recalled_ids
      assert second.id in recalled_ids
    end

    test "a legitimately empty scope on the healthy path returns [] with fallback: false" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      assert %{results: [], meta: %{total_count: 0, fallback: false, reason: nil}} =
               Memory.recall(scope, query: "anything")
    end

    test "long-term write past the per-(tenant, subject) cap returns {:error, :quota_exceeded}" do
      scope = fixture(:memory_scope)
      cap = Application.get_env(:loopctl, :max_long_term_memories_per_subject)

      for i <- 1..cap do
        assert {:ok, _} = Memory.remember(scope, %{tier: :long_term, text: "fact #{i}"})
      end

      assert {:error, :quota_exceeded} =
               Memory.remember(scope, %{tier: :long_term, text: "one too many"})
    end
  end

  # --- TC-28.2.2: session remembers + session_history ---

  describe "remember/2 (:session) + session_history/2" do
    test "returns session memories in insertion order with total_count and no embedding" do
      scope = fixture(:memory_scope)

      {:ok, m1} =
        Memory.remember(scope, %{
          tier: :session,
          session_id: "s1",
          role: :user,
          content: "first turn",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, m2} =
        Memory.remember(scope, %{
          tier: :session,
          session_id: "s1",
          role: :assistant,
          content: "second turn",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert %{results: [r1, r2], meta: %{total_count: 2}} =
               Memory.session_history(scope, session_id: "s1")

      assert r1.id == m1.id
      assert r2.id == m2.id
      refute Map.has_key?(r1, :embedding)
    end

    # AC-29.2.10: the server GOVERNS the session-turn lifetime so a turn always
    # outlives the promotion sweep (turns are promoted before pruned). This is what
    # makes assert_promotion_ttl_invariant!/0 load-bearing — both knobs govern the
    # real per-row expires_at.
    test "an omitted expires_at defaults to now + session_memory_ttl_seconds" do
      scope = fixture(:memory_scope)
      ttl = Application.get_env(:loopctl, :session_memory_ttl_seconds, 3600)

      {:ok, mem} =
        Memory.remember(scope, %{tier: :session, session_id: "s1", role: :user, content: "t"})

      seconds = DateTime.diff(mem.expires_at, DateTime.utc_now())
      # Within a small window of the configured TTL (default 3600).
      assert_in_delta seconds, ttl, 30
    end

    test "a caller-supplied expires_at shorter than the sweep window is floored up" do
      scope = fixture(:memory_scope)
      window = Application.get_env(:loopctl, :memory_promotion_sweep_window_seconds, 600)

      {:ok, mem} =
        Memory.remember(scope, %{
          tier: :session,
          session_id: "s1",
          role: :user,
          content: "t",
          # 60s — well under the sweep window, so a prune could beat promotion.
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      seconds = DateTime.diff(mem.expires_at, DateTime.utc_now())
      # Floored up to at least now + sweep_window (the expiry floor), not the requested 60.
      assert_in_delta seconds, window, 30
    end

    test "a caller-supplied expires_at beyond the floor is preserved" do
      scope = fixture(:memory_scope)

      {:ok, mem} =
        Memory.remember(scope, %{
          tier: :session,
          session_id: "s1",
          role: :user,
          content: "t",
          expires_at: DateTime.add(DateTime.utc_now(), 7200, :second)
        })

      seconds = DateTime.diff(mem.expires_at, DateTime.utc_now())
      assert_in_delta seconds, 7200, 30
    end
  end

  # --- TC-28.2.3: cross-subject / cross-tenant isolation + forget + guard ---

  describe "isolation (AC-28.2.2 / AC-28.2.5)" do
    test "recall and forget are isolated across subject AND tenant; guard rejects a subject-less query" do
      tenant_a = fixture(:tenant)
      scope_a = fixture(:memory_scope, %{tenant_id: tenant_a.id, subject_id: "subj-a"})
      scope_b = fixture(:memory_scope, %{tenant_id: tenant_a.id, subject_id: "subj-b"})
      scope_u = fixture(:memory_scope, %{subject_id: "subj-a"})
      Knowledge.reset_circuit_breaker(tenant_a.id)
      Knowledge.reset_circuit_breaker(scope_u.tenant_id)

      {:ok, m} = Memory.remember(scope_a, %{tier: :long_term, text: "secret alpha"})

      # A different subject in the same tenant cannot recall it.
      assert %{results: []} = Memory.recall(scope_b, query: "secret")
      # A different tenant (even same subject_id string) cannot recall it.
      assert %{results: []} = Memory.recall(scope_u, query: "secret")

      # forget from a foreign subject is a no-op that does not leak existence.
      assert {:error, :not_found} = Memory.forget(scope_b, m.id)
      # ...and the memory survives for its owner.
      assert %{results: [{owned, _} | _]} = Memory.recall(scope_a, query: "secret")
      assert owned.id == m.id

      # A raw memory heavy-read query missing the subject_id predicate RAISES.
      subjectless = from(mm in MemorySchema, where: mm.tenant_id == ^scope_a.tenant_id)

      assert_raise ArgumentError, ~r/subject/, fn ->
        HeavyRead.all_memory(scope_a.tenant_id, scope_a.subject_id, subjectless, [])
      end
    end
  end

  # --- TC-28.2.4: graceful degradation (embeddings unavailable) ---

  describe "recall/2 degradation (AC-28.2.4)" do
    test "non-empty scope falls back to ILIKE with fallback: true; empty scope is distinguishable" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      # Force generate_embedding to fail so recall must take the ILIKE fallback.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :no_api_key}
      end)

      {:ok, _} = Memory.remember(scope, %{tier: :long_term, text: "remember the alamo"})

      assert %{results: [{m, _score} | _], meta: %{fallback: true, reason: reason}} =
               Memory.recall(scope, query: "alamo")

      assert is_binary(reason)
      assert m.text =~ "alamo"

      # An empty scope under the same (open) degradation still signals fallback: true
      # — distinguishable from a silent healthy empty result.
      empty_scope = fixture(:memory_scope)

      assert %{results: [], meta: %{fallback: true, reason: _}} =
               Memory.recall(empty_scope, query: "alamo")
    end
  end

  # --- #411 Gap 2: recall merges global ∪ active-project ---

  describe "recall/2 project scoping (merged global ∪ active-project, #411 Gap 2)" do
    setup do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      proj_a = fixture(:project, %{tenant_id: tenant.id})
      proj_b = fixture(:project, %{tenant_id: tenant.id})
      subject_id = "subject-#{System.unique_integer([:positive])}"

      global = %Scope{tenant_id: tenant.id, subject_id: subject_id, project_id: nil}
      a = %{global | project_id: proj_a.id}
      b = %{global | project_id: proj_b.id}

      %{global: global, a: a, b: b, proj_a: proj_a, proj_b: proj_b}
    end

    test "semantic path: an active project_id merges global ∪ that project, excludes another project",
         %{global: global, a: a, b: b} do
      {:ok, g} = Memory.remember(global, %{tier: :long_term, text: "global widgets fact"})
      {:ok, ma} = Memory.remember(a, %{tier: :long_term, text: "project alpha widgets fact"})
      {:ok, mb} = Memory.remember(b, %{tier: :long_term, text: "project beta widgets fact"})

      ids = default_recall_ids(a, "widgets")

      assert %{meta: %{fallback: false}} = Memory.recall(a, query: "widgets", limit: 10)
      assert g.id in ids
      assert ma.id in ids
      refute mb.id in ids
    end

    test "semantic path: a nil project_id returns global-only (excludes any project-scoped memory)",
         %{global: global, a: a, b: b} do
      {:ok, g} = Memory.remember(global, %{tier: :long_term, text: "global widgets fact"})
      {:ok, ma} = Memory.remember(a, %{tier: :long_term, text: "project alpha widgets fact"})
      {:ok, mb} = Memory.remember(b, %{tier: :long_term, text: "project beta widgets fact"})

      ids = default_recall_ids(global, "widgets")

      assert g.id in ids
      refute ma.id in ids
      refute mb.id in ids
    end

    test "fallback path: an active project_id merges global ∪ that project, excludes another project",
         %{global: global, a: a, b: b} do
      # Force the ILIKE fallback for the whole test.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :no_api_key}
      end)

      {:ok, g} = Memory.remember(global, %{tier: :long_term, text: "global widgets fact"})
      {:ok, ma} = Memory.remember(a, %{tier: :long_term, text: "project alpha widgets fact"})
      {:ok, mb} = Memory.remember(b, %{tier: :long_term, text: "project beta widgets fact"})

      assert %{results: results, meta: %{fallback: true}} =
               Memory.recall(a, query: "widgets", limit: 10)

      ids = Enum.map(results, fn {m, _} -> m.id end)

      assert g.id in ids
      assert ma.id in ids
      refute mb.id in ids
    end

    test "fallback path: a nil project_id returns global-only", %{global: global, a: a, b: b} do
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :no_api_key}
      end)

      {:ok, g} = Memory.remember(global, %{tier: :long_term, text: "global widgets fact"})
      {:ok, ma} = Memory.remember(a, %{tier: :long_term, text: "project alpha widgets fact"})
      {:ok, mb} = Memory.remember(b, %{tier: :long_term, text: "project beta widgets fact"})

      assert %{results: results, meta: %{fallback: true}} =
               Memory.recall(global, query: "widgets", limit: 10)

      ids = Enum.map(results, fn {m, _} -> m.id end)

      assert g.id in ids
      refute ma.id in ids
      refute mb.id in ids
    end

    test "a malformed project_id does not raise and is treated as global-only", %{
      global: global,
      a: a
    } do
      {:ok, g} = Memory.remember(global, %{tier: :long_term, text: "global widgets fact"})
      {:ok, ma} = Memory.remember(a, %{tier: :long_term, text: "project alpha widgets fact"})

      malformed = %{global | project_id: "not-a-uuid"}

      # Semantic path.
      assert %{results: results} = Memory.recall(malformed, query: "widgets", limit: 10)
      ids = Enum.map(results, fn {m, _} -> m.id end)
      assert g.id in ids
      refute ma.id in ids

      # Fallback path.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:error, :no_api_key}
      end)

      assert %{results: fb_results, meta: %{fallback: true}} =
               Memory.recall(malformed, query: "widgets", limit: 10)

      fb_ids = Enum.map(fb_results, fn {m, _} -> m.id end)
      assert g.id in fb_ids
      refute ma.id in fb_ids
    end

    test "semantic path: project scoping compounds pool under-fill — meta.underfilled flags a project-scoped page starved by other-project pool dominance",
         %{a: a, b: b} do
      # The inner ANN over-fetch pool is sized for SUBJECT dilution only and is
      # project-AGNOSTIC (project scoping is a SECOND outer filter, #411 Gap 2). So a
      # subject whose nearest neighbours are dominated by OTHER-project rows can
      # under-fill a project-scoped recall even when >= k in-scope rows exist beyond
      # the pool horizon. In test the pool is capped at 6 (config/test.exs), so 6
      # nearer other-project rows fully occupy it and push the one in-scope row past
      # the horizon. `meta.underfilled` MUST surface that (the SAME accepted tradeoff
      # as the cross-subject case verified at prod scale in `ScaleRecallTest` /
      # US-28.5, here made deterministic with a tiny fixed pool + fixed embeddings).
      near = List.replace_at(List.duplicate(0.0, 1536), 0, 1.0)
      far = List.replace_at(List.duplicate(0.0, 1536), 1, 1.0)

      # Deterministic distances: "NEAR"-tagged text (query + the 6 pool fillers) embeds
      # to `near` (cosine distance 0), everything else to the orthogonal `far`
      # (distance 1). Used at BOTH write time (inline embedding worker) and recall time.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
        if String.contains?(text, "NEAR"), do: {:ok, near}, else: {:ok, far}
      end)

      # 6 other-project (proj_b) rows are the globally-nearest → they fill the whole
      # size-6 pool.
      for i <- 1..6 do
        {:ok, _} = Memory.remember(b, %{tier: :long_term, text: "NEAR pool filler #{i}"})
      end

      # One in-scope (proj_a) row, FARTHER than every pool row → rank 7, beyond the
      # size-6 pool horizon.
      {:ok, in_scope} =
        Memory.remember(a, %{tier: :long_term, text: "far in-scope alpha fact"})

      %{results: results, meta: meta} = Memory.recall(a, query: "NEAR needle", limit: 1)

      # The size-6 pool held only other-project rows, which the outer project filter
      # discards → an empty page, flagged under-filled, even though an in-scope row
      # exists beyond the horizon. This is the compounded post-pool selectivity the
      # subject-only pool sizing does not account for.
      assert meta.fallback == false
      assert results == []
      assert meta.underfilled

      # Proof the in-scope row genuinely exists (it is simply beyond the pool horizon,
      # not absent): the subject-scoped list surfaces it.
      assert in_scope.id in default_list_ids(a)
    end
  end

  # --- TC-28.2.5: supersede ---

  describe "supersede/3 (AC-28.2.7)" do
    test "supersede excludes old from recall + default list; include_superseded surfaces both" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      {:ok, old} = Memory.remember(scope, %{tier: :long_term, text: "old truth about ecto"})
      {:ok, new} = Memory.remember(scope, %{tier: :long_term, text: "new truth about ecto"})

      assert {:ok, superseded} = Memory.supersede(scope, old.id, new.id)
      assert superseded.superseded_by == new.id

      # recall excludes the superseded row.
      recalled_ids =
        scope
        |> Memory.recall(query: "ecto", limit: 10)
        |> Map.fetch!(:results)
        |> Enum.map(fn {m, _} -> m.id end)

      refute old.id in recalled_ids
      assert new.id in recalled_ids

      # default list excludes old, includes new.
      default_ids = scope |> Memory.list() |> Map.fetch!(:results) |> Enum.map(& &1.id)
      refute old.id in default_ids
      assert new.id in default_ids

      # include_superseded surfaces both.
      all_ids =
        scope
        |> Memory.list(%{include_superseded: true})
        |> Map.fetch!(:results)
        |> Enum.map(& &1.id)

      assert old.id in all_ids
      assert new.id in all_ids
    end

    test "a foreign-scope id returns {:error, :not_found} and self-supersede is rejected" do
      scope = fixture(:memory_scope)
      other = fixture(:memory_scope)
      {:ok, a} = Memory.remember(scope, %{tier: :long_term, text: "a"})
      {:ok, b} = Memory.remember(scope, %{tier: :long_term, text: "b"})
      {:ok, foreign} = Memory.remember(other, %{tier: :long_term, text: "foreign"})

      assert {:error, :not_found} = Memory.supersede(scope, a.id, foreign.id)
      assert {:error, :self_supersede} = Memory.supersede(scope, a.id, a.id)
      assert {:ok, _} = Memory.supersede(scope, a.id, b.id)
      # The A<->B cycle is refused.
      assert {:error, :cycle} = Memory.supersede(scope, b.id, a.id)
    end

    test "a 3+ node cycle is refused (no chain closes with every row hidden)" do
      scope = fixture(:memory_scope)

      {:ok, a} = Memory.remember(scope, %{tier: :long_term, text: "a"})
      {:ok, b} = Memory.remember(scope, %{tier: :long_term, text: "b"})
      {:ok, c} = Memory.remember(scope, %{tier: :long_term, text: "c"})

      # A -> B -> C, each pointing at a LIVE head.
      assert {:ok, _} = Memory.supersede(scope, a.id, b.id)
      assert {:ok, _} = Memory.supersede(scope, b.id, c.id)

      # Closing C -> A would form A->B->C->A with NO live survivor. `A` is already
      # superseded (by B), so it is not a live head and the supersede is refused —
      # the guard requires `new_id` to be live, structurally preventing cycles of any
      # length (not just the direct A<->B case).
      assert {:error, :cycle} = Memory.supersede(scope, c.id, a.id)

      # C remains the live head, still recallable via default list.
      live_ids = scope |> Memory.list() |> Map.fetch!(:results) |> Enum.map(& &1.id)
      assert c.id in live_ids
    end

    test "superseding into an already-superseded (dead) new_id is refused" do
      scope = fixture(:memory_scope)

      {:ok, a} = Memory.remember(scope, %{tier: :long_term, text: "a"})
      {:ok, b} = Memory.remember(scope, %{tier: :long_term, text: "b"})
      {:ok, c} = Memory.remember(scope, %{tier: :long_term, text: "c"})

      # B is superseded by C (B is now dead).
      assert {:ok, _} = Memory.supersede(scope, b.id, c.id)

      # Pointing a live A at the DEAD B would hide A behind a non-live head. Refused.
      assert {:error, :cycle} = Memory.supersede(scope, a.id, b.id)

      # A is untouched — still a live head.
      reloaded = AdminRepo.get(MemorySchema, a.id)
      assert is_nil(reloaded.superseded_by)
    end

    test "superseding an ALREADY-superseded old is refused — no second live head" do
      scope = fixture(:memory_scope)

      {:ok, a} = Memory.remember(scope, %{tier: :long_term, text: "a"})
      {:ok, b} = Memory.remember(scope, %{tier: :long_term, text: "b"})
      {:ok, c} = Memory.remember(scope, %{tier: :long_term, text: "c"})

      # a -> b (a superseded).
      assert {:ok, _} = Memory.supersede(scope, a.id, b.id)

      # Re-superseding a (now dead) at a DIFFERENT new head c would overwrite a's
      # pointer, orphaning b and leaving BOTH b and c live for one logical fact.
      # Refused so double-supersede cannot create two live heads (AC-29.2.4 guard).
      assert {:error, :already_superseded} = Memory.supersede(scope, a.id, c.id)

      # a still points at b; both b and c remain live heads independently, but a is not
      # duplicated behind two of them.
      reloaded = AdminRepo.get(MemorySchema, a.id)
      assert reloaded.superseded_by == b.id
    end

    test "re-superseding the SAME (old, new) pair is idempotent" do
      scope = fixture(:memory_scope)

      {:ok, a} = Memory.remember(scope, %{tier: :long_term, text: "a"})
      {:ok, b} = Memory.remember(scope, %{tier: :long_term, text: "b"})

      assert {:ok, _} = Memory.supersede(scope, a.id, b.id)
      # Idempotent replay (e.g. a retried worker) is a no-op success, not an error.
      assert {:ok, again} = Memory.supersede(scope, a.id, b.id)
      assert again.superseded_by == b.id
    end
  end

  # --- recall include_superseded + superseder-delete nilify (AC-28.2.5 / AC-28.2.7) ---

  describe "recall/2 include_superseded + forget/2 of a superseder (AC-28.2.5)" do
    test "recall with include_superseded: true surfaces the superseded row; default hides it" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      {:ok, old} = Memory.remember(scope, %{tier: :long_term, text: "old truth about elixir"})
      {:ok, new} = Memory.remember(scope, %{tier: :long_term, text: "new truth about elixir"})
      assert {:ok, _} = Memory.supersede(scope, old.id, new.id)

      # Default recall excludes the superseded row...
      default_ids =
        scope
        |> Memory.recall(query: "elixir", limit: 10)
        |> Map.fetch!(:results)
        |> Enum.map(fn {m, _} -> m.id end)

      refute old.id in default_ids

      # ...but include_superseded: true surfaces it.
      included_ids =
        scope
        |> Memory.recall(query: "elixir", limit: 10, include_superseded: true)
        |> Map.fetch!(:results)
        |> Enum.map(fn {m, _} -> m.id end)

      assert old.id in included_ids
      assert new.id in included_ids
    end

    test "deleting the superseder nilifies dependents (on_delete: :nilify_all) so no memory stays hidden" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      {:ok, old} = Memory.remember(scope, %{tier: :long_term, text: "old truth about phoenix"})
      {:ok, new} = Memory.remember(scope, %{tier: :long_term, text: "new truth about phoenix"})
      assert {:ok, _} = Memory.supersede(scope, old.id, new.id)

      # While superseded, old is hidden from default recall + list.
      refute old.id in default_recall_ids(scope, "phoenix")
      refute old.id in default_list_ids(scope)

      # Delete the SUPERSEDER; on_delete: :nilify_all clears old.superseded_by.
      assert {:ok, :deleted} = Memory.forget(scope, new.id)

      reloaded = AdminRepo.get(MemorySchema, old.id)
      assert is_nil(reloaded.superseded_by)

      # old is no longer superseded, so it reappears in default recall AND list.
      assert old.id in default_recall_ids(scope, "phoenix")
      assert old.id in default_list_ids(scope)
    end
  end

  # --- TC-28.2.6: list pagination ---

  describe "list/2 pagination (AC-28.2.5)" do
    test "paginates with an accurate total_count and no silent cap" do
      scope = fixture(:memory_scope)

      for i <- 1..25 do
        {:ok, _} = Memory.remember(scope, %{tier: :long_term, text: "memory #{i}"})
      end

      assert %{results: page1, meta: %{total_count: 25, limit: 10, offset: 0}} =
               Memory.list(scope, %{limit: 10, offset: 0})

      assert length(page1) == 10

      assert %{results: page3, meta: %{total_count: 25, offset: 20}} =
               Memory.list(scope, %{limit: 10, offset: 20})

      assert length(page3) == 5
    end
  end

  # --- Scale recall (subject not starved at scale) is now IMPLEMENTED, not stubbed,
  #     by the terminal story US-28.5: see `Loopctl.Memory.ScaleRecallTest`
  #     (`@tag :scale`, seeds a ~80k multi-subject corpus via
  #     `Loopctl.Memory.ScaleSeed` and asserts subject A recalls its own top-k). ---

  # --- tenant isolation via forget across tenants (mandatory) ---

  describe "tenant isolation" do
    test "forget cannot delete another tenant's memory (no cross-tenant delete)" do
      scope_a = fixture(:memory_scope)
      scope_b = fixture(:memory_scope)
      {:ok, m} = Memory.remember(scope_a, %{tier: :long_term, text: "tenant-a secret"})

      # scope_b (different tenant) cannot forget tenant A's memory.
      assert {:error, :not_found} = Memory.forget(scope_b, m.id)
      # The row still exists for tenant A.
      assert AdminRepo.get(MemorySchema, m.id)
    end
  end

  # --- US-28.3: superadmin oversight context functions ---

  describe "list_all_subjects/2 (US-28.3 AC-28.3.4)" do
    test "lists every subject's memories in the tenant, but never another tenant's" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)

      fixture(:memory, %{tenant_id: tenant.id, subject_id: "s1", text: "one"})
      fixture(:memory, %{tenant_id: tenant.id, subject_id: "s2", text: "two"})
      fixture(:memory, %{tenant_id: other.id, subject_id: "s1", text: "foreign"})

      %{results: results, meta: meta} = Memory.list_all_subjects(tenant.id)

      subjects = results |> Enum.map(& &1.subject_id) |> Enum.uniq() |> Enum.sort()
      assert subjects == ["s1", "s2"]
      assert meta.total_count == 2
      refute Enum.any?(results, &(&1.text == "foreign"))
    end

    test "honors limit/offset and excludes superseded by default" do
      tenant = fixture(:tenant)
      live = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s1", text: "live"})
      dead = fixture(:memory, %{tenant_id: tenant.id, subject_id: "s2", text: "dead"})

      dead
      |> Ecto.Changeset.change(superseded_by: live.id)
      |> AdminRepo.update!()

      %{results: results, meta: meta} = Memory.list_all_subjects(tenant.id)
      assert meta.total_count == 1
      assert [%{id: id}] = results
      assert id == live.id

      # include_superseded surfaces the dead row too.
      assert %{meta: %{total_count: 2}} =
               Memory.list_all_subjects(tenant.id, include_superseded: true)
    end
  end

  describe "forget_any/2 (US-28.3 AC-28.3.4)" do
    test "deletes any subject's memory in the tenant" do
      tenant = fixture(:tenant)
      mem = fixture(:memory, %{tenant_id: tenant.id, subject_id: "someone-else"})

      assert {:ok, :deleted} = Memory.forget_any(tenant.id, mem.id)
      refute AdminRepo.get(MemorySchema, mem.id)
    end

    test "a foreign-tenant id or invalid UUID returns :not_found (no leak)" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      foreign = fixture(:memory, %{tenant_id: other.id, subject_id: "x"})

      assert {:error, :not_found} = Memory.forget_any(tenant.id, foreign.id)
      assert {:error, :not_found} = Memory.forget_any(tenant.id, "not-a-uuid")
      # The foreign row survives.
      assert AdminRepo.get(MemorySchema, foreign.id)
    end
  end

  # --- US-29.3: :source filter on list/2 and list_all_subjects/2 ---

  describe "list/2 :source filter (US-29.3)" do
    test "filters the caller's own memories by promoted / explicit provenance" do
      scope = fixture(:memory_scope)

      fixture(:memory, %{
        tenant_id: scope.tenant_id,
        subject_id: scope.subject_id,
        source: :explicit,
        text: "explicit fact"
      })

      fixture(:memory, %{
        tenant_id: scope.tenant_id,
        subject_id: scope.subject_id,
        source: :promoted,
        source_session_id: "s1",
        text: "promoted fact"
      })

      %{results: promoted} = Memory.list(scope, %{source: "promoted"})
      assert Enum.map(promoted, & &1.text) == ["promoted fact"]
      assert Enum.all?(promoted, &(&1.source == :promoted))

      %{results: explicit} = Memory.list(scope, %{source: "explicit"})
      assert Enum.map(explicit, & &1.text) == ["explicit fact"]
      assert Enum.all?(explicit, &(&1.source == :explicit))

      # No/unknown source → both rows.
      assert %{meta: %{total_count: 2}} = Memory.list(scope, %{})
      assert %{meta: %{total_count: 2}} = Memory.list(scope, %{source: "bogus"})
    end
  end

  describe "list_all_subjects/2 :source filter (US-29.3)" do
    test "a superadmin oversight list can filter provenance across subjects" do
      tenant = fixture(:tenant)

      fixture(:memory, %{tenant_id: tenant.id, subject_id: "s1", source: :explicit, text: "e1"})

      fixture(:memory, %{
        tenant_id: tenant.id,
        subject_id: "s2",
        source: :promoted,
        source_session_id: "sess-2",
        text: "p2"
      })

      %{results: promoted, meta: pmeta} =
        Memory.list_all_subjects(tenant.id, %{source: :promoted})

      assert pmeta.total_count == 1
      assert Enum.map(promoted, & &1.text) == ["p2"]

      %{results: explicit, meta: emeta} =
        Memory.list_all_subjects(tenant.id, %{source: :explicit})

      assert emeta.total_count == 1
      assert Enum.map(explicit, & &1.text) == ["e1"]

      # Unfiltered → both subjects.
      assert %{meta: %{total_count: 2}} = Memory.list_all_subjects(tenant.id)
    end
  end

  defp default_recall_ids(scope, query) do
    scope
    |> Memory.recall(query: query, limit: 10)
    |> Map.fetch!(:results)
    |> Enum.map(fn {m, _} -> m.id end)
  end

  defp default_list_ids(scope) do
    scope
    |> Memory.list()
    |> Map.fetch!(:results)
    |> Enum.map(& &1.id)
  end
end
