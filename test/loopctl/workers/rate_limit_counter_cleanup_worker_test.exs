defmodule Loopctl.Workers.RateLimitCounterCleanupWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Workers.RateLimitCounterCleanupWorker

  @insert """
  INSERT INTO rate_limit_counters (id, bucket, window_start, count, inserted_at, updated_at)
  VALUES (gen_random_uuid(), $1, $2, 1, (now() AT TIME ZONE 'UTC'), (now() AT TIME ZONE 'UTC'))
  """

  defp insert_counter(bucket, window_start) do
    AdminRepo.query!(@insert, [bucket, window_start])
  end

  defp count_for(bucket) do
    %{rows: [[n]]} =
      AdminRepo.query!("SELECT count(*) FROM rate_limit_counters WHERE bucket = $1", [bucket])

    n
  end

  describe "perform/1" do
    test "deletes expired windows but keeps the current window" do
      now_ms = System.system_time(:millisecond)
      bucket = "test:cleanup:#{Ecto.UUID.generate()}"

      # An old (expired) window — clearly past the retention floor (25h old, well
      # beyond the 2h floor even accounting for the widest 1h window).
      insert_counter(bucket, now_ms - 25 * 3_600_000)
      # A current window — must survive.
      current_window = div(now_ms, 60_000) * 60_000
      insert_counter(bucket, current_window)

      assert count_for(bucket) == 2

      assert :ok = RateLimitCounterCleanupWorker.perform(%Oban.Job{})

      # Only the current window remains.
      assert count_for(bucket) == 1

      %{rows: [[remaining_window]]} =
        AdminRepo.query!(
          "SELECT window_start FROM rate_limit_counters WHERE bucket = $1",
          [bucket]
        )

      assert remaining_window == current_window
    end

    test "a still-in-flight window of the WIDEST size (1h) is NOT pruned" do
      # Regression guard for the retention-floor margin: the widest window a
      # caller uses is 1h (signup/enroll/WebAuthn). A 1h window that opened up to
      # 1h ago is still live, and MUST survive cleanup — otherwise its counter
      # resets mid-window and a full budget is over-admitted. With the floor at
      # 2× the widest window (2h) this window (1h old) is safely retained; with a
      # naive floor equal to the widest window (1h) it would be pruned exactly at
      # the boundary. This is the boundary the 60s-only test never exercised.
      now_ms = System.system_time(:millisecond)
      bucket = "test:cleanup-widest:#{Ecto.UUID.generate()}"

      # A 1h-old window start (still in-flight for a 1h window).
      one_hour_old = now_ms - 3_600_000
      insert_counter(bucket, one_hour_old)

      assert count_for(bucket) == 1
      assert :ok = RateLimitCounterCleanupWorker.perform(%Oban.Job{})
      assert count_for(bucket) == 1
    end

    test "succeeds when there are no expired windows" do
      assert :ok = RateLimitCounterCleanupWorker.perform(%Oban.Job{})
    end
  end
end
