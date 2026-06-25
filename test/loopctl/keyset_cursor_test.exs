defmodule Loopctl.KeysetCursorTest do
  @moduledoc """
  Tests for the shared `Loopctl.KeysetCursor` codec and the NAMESPACE SEPARATION it
  guarantees between the per-surface delegators (`Loopctl.Knowledge.ArticleCursor`,
  `Loopctl.Audit.ChangesCursor`).

  The per-surface tamper/tenant/round-trip behavior is covered by
  `article_cursor_test.exs` (unchanged after the refactor — proving it is
  behavior-preserving). This file pins the cross-namespace invariant: a cursor minted
  for one surface MUST NOT decode on another, even within the same tenant.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Audit.ChangesCursor
  alias Loopctl.KeysetCursor
  alias Loopctl.Knowledge.ArticleCursor

  setup do
    %{
      tenant_id: Ecto.UUID.generate(),
      position: {~U[2026-06-24 09:00:00.123456Z], Ecto.UUID.generate()}
    }
  end

  describe "shared codec round-trip" do
    test "encode/3 + decode/3 round-trip under a namespace", %{tenant_id: t, position: pos} do
      cursor = KeysetCursor.encode("article_cursor", t, pos)
      assert {:ok, ^pos} = KeysetCursor.decode("article_cursor", t, cursor)
    end

    test "a different namespace fails verification for the same tenant+position",
         %{tenant_id: t, position: pos} do
      cursor = KeysetCursor.encode("article_cursor", t, pos)
      assert {:error, :invalid} = KeysetCursor.decode("changes_cursor", t, cursor)
    end

    test "a different tenant fails verification under the same namespace",
         %{tenant_id: t, position: pos} do
      cursor = KeysetCursor.encode("article_cursor", t, pos)

      assert {:error, :invalid} =
               KeysetCursor.decode("article_cursor", Ecto.UUID.generate(), cursor)
    end
  end

  describe "namespace separation across delegators (security: no cross-surface replay)" do
    test "an article cursor does NOT decode as a change cursor (same tenant)",
         %{tenant_id: t, position: pos} do
      article_cursor = ArticleCursor.encode(t, pos)

      # Round-trips as an article cursor...
      assert {:ok, ^pos} = ArticleCursor.decode(t, article_cursor)
      # ...but is rejected by the change-feed surface.
      assert {:error, :invalid} = ChangesCursor.decode(t, article_cursor)
    end

    test "a change cursor does NOT decode as an article cursor (same tenant)",
         %{tenant_id: t, position: pos} do
      change_cursor = ChangesCursor.encode(t, pos)

      assert {:ok, ^pos} = ChangesCursor.decode(t, change_cursor)
      assert {:error, :invalid} = ArticleCursor.decode(t, change_cursor)
    end
  end

  describe "delegators preserve the defensive contract" do
    test "garbage is rejected by both delegators, never raises", %{tenant_id: t} do
      assert {:error, :invalid} = ArticleCursor.decode(t, "not-a-cursor!!!")
      assert {:error, :invalid} = ChangesCursor.decode(t, "not-a-cursor!!!")
    end

    test "a non-binary cursor is rejected, never raises", %{tenant_id: t} do
      assert {:error, :invalid} = ArticleCursor.decode(t, nil)
      assert {:error, :invalid} = ChangesCursor.decode(t, nil)
    end
  end
end
