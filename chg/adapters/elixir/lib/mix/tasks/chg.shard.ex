defmodule Mix.Tasks.Chg.Shard do
  @shortdoc "Runs one shard of the full suite (contract command `shard`)"
  @moduledoc """
  Runs shard `--index` (1-based) of `--of` shards of the whole suite. A test file belongs
  to shard `:erlang.phash2(path, of) + 1`, so the split is stable across machines.

      mix chg.shard --of <n> --index <i>

  `mix test --partitions` is not used: it reads its index from `MIX_TEST_PARTITION`, which
  the adapter's `isolation_env` already spends on the per-workspace test database.
  """
  use Mix.Task

  @impl true
  def run(args) do
    ChgAdapter.in_test_env("chg.shard", args, fn -> do_run(args) end)
  end

  defp do_run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [of: :integer, index: :integer])
    n = opts[:of] || Mix.raise("mix chg.shard needs --of <n>")
    i = opts[:index] || Mix.raise("mix chg.shard needs --index <i>")
    unless i in 1..n//1, do: Mix.raise("--index must be in 1..#{n}")

    ChgAdapter.Runner.run(shard(ChgAdapter.test_files(), n, i), true)
  end

  @doc false
  def shard(files, n, i), do: Enum.filter(files, &(:erlang.phash2(&1, n) + 1 == i))
end
