defmodule Loopctl.RateLimiter.ServerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.RateLimiter.Server

  describe "check_rate/2" do
    test "allows requests under the limit" do
      id = "test-key-#{System.unique_integer([:positive])}"

      assert {:allow, 1} = Server.check_rate(id, 5)
      assert {:allow, 2} = Server.check_rate(id, 5)
      assert {:allow, 3} = Server.check_rate(id, 5)
    end

    test "denies requests over the limit" do
      id = "test-key-#{System.unique_integer([:positive])}"

      # Fill up the limit
      for _ <- 1..3, do: Server.check_rate(id, 3)

      assert {:deny, 3} = Server.check_rate(id, 3)
    end

    test "different identifiers have independent counters" do
      id_a = "key-a-#{System.unique_integer([:positive])}"
      id_b = "key-b-#{System.unique_integer([:positive])}"

      Server.check_rate(id_a, 10)
      Server.check_rate(id_a, 10)
      Server.check_rate(id_a, 10)

      assert {:allow, 1} = Server.check_rate(id_b, 10)
    end
  end

  describe "current_count/1" do
    test "returns 0 for unknown identifier" do
      assert Server.current_count("unknown-#{System.unique_integer([:positive])}") == 0
    end

    test "returns current count after increments" do
      id = "count-test-#{System.unique_integer([:positive])}"

      Server.check_rate(id, 100)
      Server.check_rate(id, 100)

      assert Server.current_count(id) == 2
    end
  end

  describe "window_info/0" do
    test "returns window and reset_at" do
      info = Server.window_info()
      assert is_integer(info.window)
      assert is_integer(info.reset_at)
      assert info.reset_at > info.window
    end
  end

  describe "cleanup" do
    test "expired entries are cleaned up" do
      # Allow the GenServer process to use our mock
      pid = Process.whereis(Server)
      Mox.allow(Loopctl.MockClock, self(), pid)

      # Insert a fake expired entry directly in ETS
      table = Server.table_name()
      expired_window = div(System.system_time(:second), 60) - 5
      :ets.insert(table, {{"expired-key", expired_window}, 42})

      # Trigger cleanup
      send(pid, :cleanup)
      # Give GenServer time to process
      _ = :sys.get_state(pid)

      # Expired entry should be gone
      assert :ets.lookup(table, {"expired-key", expired_window}) == []
    end
  end
end
