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
