defmodule Loopctl.LogValueTest do
  use ExUnit.Case, async: true

  alias Loopctl.LogValue

  describe "epoch/1" do
    test "a non-negative integer a bigint holds is itself, at both ends of the range" do
      assert LogValue.epoch(0) == 0
      assert LogValue.epoch(7) == 7
      assert LogValue.epoch(9_223_372_036_854_775_807) == 9_223_372_036_854_775_807
    end

    test "anything else is :invalid, never the value" do
      for value <- [
            -1,
            9_223_372_036_854_775_808,
            Integer.pow(10, 5_000),
            "1",
            1.0,
            %{"nested" => 1},
            [1]
          ] do
        assert LogValue.epoch(value) == :invalid, inspect(value, limit: 3)
      end
    end

    test "absent stays nil" do
      assert LogValue.epoch(nil) == nil
    end
  end

  describe "uuid/1" do
    test "a UUID is itself, normalized to lowercase" do
      id = Ecto.UUID.generate()
      assert LogValue.uuid(id) == id
      assert LogValue.uuid(String.upcase(id)) == id
    end

    test "anything else is :invalid, never the value" do
      raw = Ecto.UUID.generate() |> Ecto.UUID.dump!()

      # A 16-byte string is a RAW UUID to Ecto.UUID.cast/1; here it is not an id at all.
      for value <- [
            "aaaaaaaaaaaaaaaa",
            raw,
            "not-a-uuid",
            String.duplicate("x", 5_000),
            1,
            %{"id" => "x"},
            ["x"]
          ] do
        assert LogValue.uuid(value) == :invalid, inspect(value, limit: 3)
      end
    end

    test "absent stays nil" do
      assert LogValue.uuid(nil) == nil
    end
  end
end
