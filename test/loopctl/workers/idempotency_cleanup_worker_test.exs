defmodule Loopctl.Workers.IdempotencyCleanupWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.IdempotencyCache
  alias Loopctl.Workers.IdempotencyCleanupWorker

  describe "perform/1" do
    test "deletes expired idempotency cache entries" do
      now = DateTime.utc_now()
      expired_at = DateTime.add(now, -3600, :second)
      future_at = DateTime.add(now, 3600, :second)

      # Insert an expired entry
      AdminRepo.insert!(%IdempotencyCache{
        idempotency_key: "expired-key-#{System.unique_integer([:positive])}",
        response_data: :erlang.term_to_binary(%{test: true}),
        expires_at: expired_at
      })

      # Insert a still-valid entry
      valid_key = "valid-key-#{System.unique_integer([:positive])}"

      AdminRepo.insert!(%IdempotencyCache{
        idempotency_key: valid_key,
        response_data: :erlang.term_to_binary(%{test: true}),
        expires_at: future_at
      })

      assert :ok = IdempotencyCleanupWorker.perform(%Oban.Job{})

      # Valid entry still exists
      assert AdminRepo.get_by(IdempotencyCache, idempotency_key: valid_key) != nil

      # Only the valid entry should remain
      remaining = AdminRepo.all(IdempotencyCache)
      assert length(remaining) == 1
      assert hd(remaining).idempotency_key == valid_key
    end

    test "succeeds when no expired entries exist" do
      assert :ok = IdempotencyCleanupWorker.perform(%Oban.Job{})
    end
  end
end
