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

      # An old (expired) window — well past the retention floor.
      insert_counter(bucket, now_ms - 7_200_000)
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

    test "succeeds when there are no expired windows" do
      assert :ok = RateLimitCounterCleanupWorker.perform(%Oban.Job{})
    end
  end
end
