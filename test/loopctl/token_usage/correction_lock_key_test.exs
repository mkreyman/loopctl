defmodule Loopctl.TokenUsage.CorrectionLockKeyTest do
  @moduledoc """
  `Loopctl.TokenUsage.correction_lock_key/2` (tokens-02, FIX 6): the key the per-story
  correction advisory lock is taken on. Pure, so async; that the lock on it serializes two
  real sessions is `Loopctl.TokenUsage.CorrectionLockTest`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.TokenUsage

  describe "correction_lock_key/2 (tokens-02, FIX 6)" do
    test "is deterministic, scoped to (tenant, story), and in signed 64-bit range" do
      tenant = Ecto.UUID.generate()
      story = Ecto.UUID.generate()

      key = TokenUsage.correction_lock_key(tenant, story)

      assert is_integer(key)
      # Release-independent: same inputs always yield the same key.
      assert TokenUsage.correction_lock_key(tenant, story) == key
      # Scoped: a different story or tenant yields a different key.
      refute TokenUsage.correction_lock_key(tenant, Ecto.UUID.generate()) == key
      refute TokenUsage.correction_lock_key(Ecto.UUID.generate(), story) == key
      # Fits a PostgreSQL bigint advisory lock key.
      assert key >= -0x8000_0000_0000_0000
      assert key <= 0x7FFF_FFFF_FFFF_FFFF
    end
  end
end
