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

  # --- Scale stub (executed by the terminal story US-28.5) ---

  @tag :scale
  @tag :skip
  test "a subject reliably recalls its own top-k when other subjects dominate the corpus" do
    # Placeholder: the assertion (subject recall under cross-subject dominance) is
    # verified at scale by US-28.5 with an ANALYZE/EXPLAIN gate proving the over-fetch
    # pool does not under-fill for a subject holding N memories among M total.
    :ok
  end

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
