defmodule LoopctlRunner.UuidTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Uuid

  @lower "0f8fad5b-d9cb-469f-a165-70867728950e"

  test "valid? reads a uuid in either case, and nothing else" do
    assert Uuid.valid?(@lower)
    assert Uuid.valid?(String.upcase(@lower))

    for bad <- [nil, 42, "", @lower <> "0", "../" <> @lower, String.replace(@lower, "-", "")] do
      refute Uuid.valid?(bad), inspect(bad)
    end
  end

  test "lowercase? takes only the lowercase spelling" do
    assert Uuid.lowercase?(@lower)
    refute Uuid.lowercase?(String.upcase(@lower))
    refute Uuid.lowercase?(nil)
    refute Uuid.lowercase?(@lower <> "\n")
  end
end
