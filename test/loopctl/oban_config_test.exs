defmodule Loopctl.ObanConfigTest do
  @moduledoc """
  US-32.2: Oban queue widths are env-driven, defaulting to the current hardcoded
  values. Pure module — no DB needed, so this uses plain ExUnit.Case (not DataCase).
  """
  use ExUnit.Case, async: true

  alias Loopctl.ObanConfig

  describe "queues/0" do
    test "TC-32.2.1: defaults preserved when OBAN_QUEUE_* env vars are unset (CI default)" do
      assert ObanConfig.queues() == [
               default: 10,
               webhooks: 5,
               cleanup: 2,
               analytics: 3,
               maintenance: 2,
               embeddings: 5,
               knowledge: 5,
               memory: 3,
               audit: 3
             ]
    end

    test "TC-32.2.4: OBAN_QUEUE_<NAME> env var overrides the matching queue's width" do
      System.put_env("OBAN_QUEUE_DEFAULT", "42")

      try do
        assert Keyword.get(ObanConfig.queues(), :default) == 42
      after
        System.delete_env("OBAN_QUEUE_DEFAULT")
      end
    end

    test "TC-32.2.4: unrelated queues stay at their default while one is overridden" do
      System.put_env("OBAN_QUEUE_WEBHOOKS", "99")

      try do
        queues = ObanConfig.queues()
        assert Keyword.get(queues, :webhooks) == 99
        assert Keyword.get(queues, :default) == 10
        assert Keyword.get(queues, :audit) == 3
      after
        System.delete_env("OBAN_QUEUE_WEBHOOKS")
      end
    end
  end

  describe "queue_size/2" do
    test "TC-32.2.2: env override applies" do
      assert ObanConfig.queue_size("20", 5) == 20
      assert ObanConfig.queue_size(nil, 5) == 5
    end

    test "TC-32.2.3: invalid values fail loud instead of returning 0 or the default" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("0", 5) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("-3", 5) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("abc", 5) end
    end

    test "TC-32.2.3: non-integer suffix (e.g. 10s) also fails loud" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> ObanConfig.queue_size("10s", 5) end
    end
  end
end
