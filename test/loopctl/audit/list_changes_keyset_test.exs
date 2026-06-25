defmodule Loopctl.Audit.ListChangesKeysetTest do
  @moduledoc """
  Context-level tests for `Loopctl.Audit.list_changes/3` as a KEYSET enumeration
  (US-27.9b / AC-27.9b.1).

  The headline fix: the original `next_since` timestamp token SKIPS or DUPLICATES
  rows that share a microsecond (bulk writes tie `inserted_at`). The `(inserted_at,
  id)` keyset cursor steps PAST a specific row regardless of ties — proven here by
  forcing a tied-timestamp batch and walking across a page boundary that lands
  mid-tie, asserting a gap-free, duplicate-free, complete walk. Also covers tenant
  isolation (the cursor never crosses tenants).
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog

  # Insert `n` audit rows for a tenant, ALL at the same `inserted_at` (a tied batch,
  # what an Ecto.Multi / insert_all commits). Returns the inserted ids.
  defp insert_tied(tenant_id, n, ts) do
    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: Ecto.UUID.generate(),
          action: "story.updated",
          actor_type: "api_key",
          new_state: %{"n" => i},
          metadata: %{},
          inserted_at: ts
        }
      end

    {_n, returned} = AdminRepo.insert_all(AuditLog, rows, returning: [:id])
    Enum.map(returned, & &1.id)
  end

  # Walk the change feed via the keyset cursor, collecting ids. Starts from the unix
  # epoch (so the first page covers everything), then follows next_cursor.
  defp walk(tenant_id, page_limit) do
    do_walk(tenant_id, page_limit, nil, [], 0)
  end

  defp do_walk(_tid, _limit, _cursor, _acc, n) when n > 10_000 do
    flunk("change-feed keyset walk did not terminate")
  end

  defp do_walk(tenant_id, page_limit, cursor, acc, n) do
    opts = if cursor, do: [limit: page_limit, cursor: cursor], else: [limit: page_limit]

    {:ok, %{data: data, next_cursor: next_cursor}} =
      Audit.list_changes(tenant_id, DateTime.from_unix!(0), opts)

    acc = acc ++ Enum.map(data, & &1.id)

    if next_cursor do
      do_walk(tenant_id, page_limit, next_cursor, acc, n + 1)
    else
      acc
    end
  end

  describe "list_changes/3 — tie-safe keyset walk (AC-27.9b.1)" do
    test "walks a tied-timestamp batch gap-free across a mid-tie page boundary" do
      tenant = fixture(:tenant)
      ts = ~U[2026-06-24 09:00:00.000000Z]

      # 10 rows ALL at the same microsecond — the exact case a since-token mishandles.
      ids = insert_tied(tenant.id, 10, ts)

      # Page size 3 forces boundaries WITHIN the tied batch.
      seen = walk(tenant.id, 3)

      assert Enum.sort(seen) == Enum.sort(ids), "every tied row served exactly once"
      assert length(seen) == 10
      assert length(seen) == length(Enum.uniq(seen)), "no duplicate across the tie boundary"
    end

    test "since-token alone would skip tied rows after a boundary (regression guard)" do
      tenant = fixture(:tenant)
      ts = ~U[2026-06-24 10:00:00.000000Z]
      ids = insert_tied(tenant.id, 6, ts)

      # First page of 3 over the 6 tied rows: more remain, and next_cursor is set.
      {:ok, %{data: page1, next_cursor: cursor, next_since: next_since}} =
        Audit.list_changes(tenant.id, DateTime.from_unix!(0), limit: 3)

      assert length(page1) == 3
      refute is_nil(cursor)
      # next_since equals the tied timestamp — a since-only follow-up (`inserted_at >
      # next_since`) would EXCLUDE the remaining 3 tied rows (the drift bug). The
      # keyset cursor instead returns them.
      assert next_since == ts

      {:ok, %{data: page2}} =
        Audit.list_changes(tenant.id, DateTime.from_unix!(0), limit: 3, cursor: cursor)

      seen = Enum.map(page1 ++ page2, & &1.id)
      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(Enum.uniq(seen)) == 6, "keyset cursor returned the tied tail with no gap"
    end
  end

  describe "list_changes/3 — back-compat since token" do
    test "no cursor: still seeks by since and emits next_since" do
      tenant = fixture(:tenant)
      base = ~U[2026-06-24 11:00:00.000000Z]

      # Distinct timestamps so the since-token is well-behaved here.
      for i <- 0..4 do
        insert_tied(tenant.id, 1, DateTime.add(base, i, :second))
      end

      {:ok, %{data: data, has_more: has_more, next_since: next_since}} =
        Audit.list_changes(tenant.id, DateTime.add(base, -1, :second), limit: 2)

      assert length(data) == 2
      assert has_more
      assert %DateTime{} = next_since
    end
  end

  describe "list_changes/3 — tenant isolation (AC-27.9b.4)" do
    test "the keyset walk never crosses tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      ts = ~U[2026-06-24 12:00:00.000000Z]

      a_ids = insert_tied(tenant_a.id, 5, ts)
      insert_tied(tenant_b.id, 5, ts)

      seen = walk(tenant_a.id, 2)

      assert Enum.sort(seen) == Enum.sort(a_ids)
      assert length(seen) == 5
    end
  end
end
