defmodule Loopctl.Knowledge.ArticleCursorTest do
  @moduledoc """
  Unit tests for the integrity-protected, tenant-bound keyset cursor (US-27.9a).

  These exercise the trust boundary directly: round-trip fidelity, wrong-tenant
  rejection (AC-27.9a.3), tamper rejection (AC-27.9a.4), and that decode NEVER
  raises — garbage in always yields `{:error, :invalid}`.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ArticleCursor

  defp tenant_id, do: Ecto.UUID.generate()

  defp position do
    # utc_datetime_usec precision: the cursor must preserve microseconds exactly.
    {DateTime.truncate(DateTime.utc_now(), :microsecond), Ecto.UUID.generate()}
  end

  describe "encode/2 + decode/2 round-trip" do
    test "round-trips the (inserted_at, id) tuple exactly" do
      tid = tenant_id()
      {inserted_at, id} = position()

      cursor = ArticleCursor.encode(tid, {inserted_at, id})
      assert is_binary(cursor)

      assert {:ok, {decoded_inserted_at, decoded_id}} = ArticleCursor.decode(tid, cursor)
      assert decoded_id == id
      assert DateTime.compare(decoded_inserted_at, inserted_at) == :eq
    end

    test "preserves sub-second microsecond precision (batch-tied timestamps)" do
      tid = tenant_id()
      # Two rows in the same insert_all batch share a timestamp to the microsecond.
      inserted_at = ~U[2026-06-24 12:00:00.123456Z]
      id = Ecto.UUID.generate()

      cursor = ArticleCursor.encode(tid, {inserted_at, id})
      assert {:ok, {decoded, ^id}} = ArticleCursor.decode(tid, cursor)
      assert decoded == inserted_at
    end

    test "produces a URL-safe value (no +, /, or = padding)" do
      cursor = ArticleCursor.encode(tenant_id(), position())
      refute cursor =~ "+"
      refute cursor =~ "/"
      refute cursor =~ "="
    end
  end

  describe "tenant binding (AC-27.9a.3)" do
    test "a cursor minted for tenant B fails verification for tenant A" do
      tenant_a = tenant_id()
      tenant_b = tenant_id()
      pos = position()

      cursor_b = ArticleCursor.encode(tenant_b, pos)

      # Same position, but tenant A's key does not verify tenant B's signature.
      assert {:error, :invalid} = ArticleCursor.decode(tenant_a, cursor_b)
      # And tenant B can still read its own cursor.
      assert {:ok, _} = ArticleCursor.decode(tenant_b, cursor_b)
    end
  end

  describe "tamper resistance (AC-27.9a.4)" do
    test "a bit-flipped cursor fails verification" do
      tid = tenant_id()
      cursor = ArticleCursor.encode(tid, position())

      tampered = flip_a_bit(cursor)
      assert tampered != cursor
      assert {:error, :invalid} = ArticleCursor.decode(tid, tampered)
    end

    test "a truncated cursor fails verification" do
      tid = tenant_id()
      cursor = ArticleCursor.encode(tid, position())

      assert {:error, :invalid} = ArticleCursor.decode(tid, String.slice(cursor, 0..-5//1))
    end
  end

  describe "defensive decode — never raises, never an oracle" do
    test "garbage strings return {:error, :invalid}" do
      tid = tenant_id()

      for junk <- ["", "garbage", "!!!not-base64!!!", "a", String.duplicate("x", 500)] do
        assert {:error, :invalid} = ArticleCursor.decode(tid, junk)
      end
    end

    test "valid base64 but undersized payload returns {:error, :invalid}" do
      tid = tenant_id()
      short = Base.url_encode64("tooshort", padding: false)
      assert {:error, :invalid} = ArticleCursor.decode(tid, short)
    end

    test "valid base64 of an arbitrary (correctly-sized) blob fails the HMAC" do
      tid = tenant_id()
      # 48 bytes = a plausible payload+sig length, but random → HMAC mismatch.
      forged = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      assert {:error, :invalid} = ArticleCursor.decode(tid, forged)
    end

    test "non-binary cursor returns {:error, :invalid}" do
      assert {:error, :invalid} = ArticleCursor.decode(tenant_id(), nil)
      assert {:error, :invalid} = ArticleCursor.decode(tenant_id(), 123)
    end
  end

  # Flip the lowest bit of the first decoded byte (the payload region), so the
  # signature no longer matches the (now-altered) payload.
  defp flip_a_bit(cursor) do
    decoded = Base.url_decode64!(cursor, padding: false)
    <<first, rest::binary>> = decoded
    Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
  end
end
