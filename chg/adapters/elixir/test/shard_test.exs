defmodule Mix.Tasks.Chg.ShardTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Chg.Shard

  @files ~w(test/a_test.exs test/b_test.exs test/c_test.exs test/d_test.exs test/e_test.exs)
  @ms %{
    "test/a_test.exs" => 900,
    "test/b_test.exs" => 500,
    "test/c_test.exs" => 400,
    "test/d_test.exs" => 100
  }

  test "a balanced split places every file exactly once, longest first to the lightest shard" do
    shards = for i <- 1..2, do: Shard.balanced(@files, @ms, 2, i)
    assert Enum.sort(List.flatten(shards)) == @files
    # e counts as the median, 500. a 900 -> 1; b 500 -> 2; e 500 -> 2 (1000);
    # c 400 -> 1 (1300); d 100 -> 2 (1100).
    assert shards == [
             ~w(test/a_test.exs test/c_test.exs),
             ~w(test/b_test.exs test/d_test.exs test/e_test.exs)
           ]
  end

  test "the split depends only on its inputs, whatever order the files come in" do
    assert Shard.balanced(Enum.reverse(@files), @ms, 3, 2) == Shard.balanced(@files, @ms, 3, 2)
  end

  test "more shards than files leaves some empty" do
    shards = for i <- 1..7, do: Shard.balanced(@files, @ms, 7, i)
    assert Enum.count(shards, &(&1 == [])) == 2
    assert Enum.sort(List.flatten(shards)) == @files
  end
end
