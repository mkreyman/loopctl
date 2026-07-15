defmodule Loopctl.Memory.DualIndexRecallTest do
  @moduledoc """
  US-38.4 / TC-38.4.3 — `memories.embedding` dual-index justification.

  The dual HNSW index on `memories.embedding` (FULL + partial `WHERE superseded_by
  IS NULL`) is KEPT because each serves a distinct, live recall path:

    * default `recall/2` (`include_superseded: false`) adds `superseded_by IS NULL`
      on the inner ANN, exactly matching the PARTIAL index predicate → served by
      `memories_live_embedding_hnsw_idx`;
    * `recall/2` with `include_superseded: true` drops that filter → the query
      predicate no longer implies the partial index's, so the planner serves the
      ANN from the FULL index (proven by EXPLAIN in docs/hnsw-tuning-evaluation.md).

  This test proves the BEHAVIOUR that justifies keeping both: default recall of LIVE
  memories is unchanged (superseded rows excluded), and the include-superseded path
  still surfaces superseded rows — so the full index is not dead. Whichever the
  dual-index outcome, LIVE-memory recall is identical (AC-38.4.3 / AC-38.4.4).

  Async: `recall/2` routes through `Loopctl.HeavyRead` (→ `AdminRepo` in test), so it
  shares the sandbox connection the fixtures insert through.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Memory

  describe "dual-index recall (keep both — TC-38.4.3)" do
    test "default recall returns only LIVE memories; include_superseded surfaces superseded too" do
      scope = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope.tenant_id)

      {:ok, old} = Memory.remember(scope, %{tier: :long_term, text: "old truth about ecto"})
      {:ok, new} = Memory.remember(scope, %{tier: :long_term, text: "new truth about ecto"})

      assert {:ok, superseded} = Memory.supersede(scope, old.id, new.id)
      assert superseded.superseded_by == new.id

      # Default recall (partial index path): the superseded `old` is EXCLUDED; live
      # `new` is present — the live-memory recall set is unchanged by the dual index.
      default_ids =
        scope
        |> Memory.recall(query: "ecto", limit: 10)
        |> recalled_ids()

      assert new.id in default_ids
      refute old.id in default_ids

      # include_superseded recall (full index path): BOTH the superseded and live rows
      # are recalled — proof the full index still serves a live code path.
      all_ids =
        scope
        |> Memory.recall(query: "ecto", limit: 10, include_superseded: true)
        |> recalled_ids()

      assert old.id in all_ids
      assert new.id in all_ids
    end

    test "include_superseded recall is tenant + subject isolated" do
      scope_a = fixture(:memory_scope)
      scope_b = fixture(:memory_scope)
      Knowledge.reset_circuit_breaker(scope_a.tenant_id)
      Knowledge.reset_circuit_breaker(scope_b.tenant_id)

      {:ok, a_old} = Memory.remember(scope_a, %{tier: :long_term, text: "shared secret alpha"})
      {:ok, a_new} = Memory.remember(scope_a, %{tier: :long_term, text: "shared secret beta"})
      assert {:ok, _} = Memory.supersede(scope_a, a_old.id, a_new.id)

      {:ok, _b} = Memory.remember(scope_b, %{tier: :long_term, text: "shared secret gamma"})

      # Tenant B's include_superseded recall never sees tenant A's superseded row.
      b_ids =
        scope_b
        |> Memory.recall(query: "secret", limit: 10, include_superseded: true)
        |> recalled_ids()

      refute a_old.id in b_ids
      refute a_new.id in b_ids
    end
  end

  defp recalled_ids(%{results: results}), do: Enum.map(results, fn {m, _score} -> m.id end)
end
