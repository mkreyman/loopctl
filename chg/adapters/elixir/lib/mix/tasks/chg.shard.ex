defmodule Mix.Tasks.Chg.Shard do
  @shortdoc "Runs one shard of the full suite (contract command `shard`)"
  @moduledoc """
  Runs shard `--index` (1-based) of `--of` shards of the whole suite.

      mix chg.shard --of <n> --index <i>

  With `CHG_SHARD_BY` naming a coverage record (`ChgAdapter.Record`), the files are split
  by their recorded time: longest first, each to the shard with the least time so far
  (ties to the lower index), and a file the record lacks counts as the median. Every
  shard of one run must be given the same record; a record that cannot be read stops the
  shard rather than split differently from its siblings. Without it, a file belongs to
  shard `:erlang.phash2(path, of) + 1`. Both splits depend only on their inputs, so they
  agree across machines.

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

    files = ChgAdapter.test_files()

    mine =
      case System.get_env("CHG_SHARD_BY") do
        by when by in [nil, ""] ->
          shard(files, n, i)

        by ->
          case ChgAdapter.Record.read(by) do
            {:ok, record} -> balanced(files, record.ms, n, i)
            {:error, why} -> Mix.raise("CHG_SHARD_BY: #{why}")
          end
      end

    ChgAdapter.Runner.run(mine, true)
  end

  @doc false
  def shard(files, n, i), do: Enum.filter(files, &(:erlang.phash2(&1, n) + 1 == i))

  @doc false
  def balanced(files, ms, n, i) do
    known = files |> Enum.map(&Map.get(ms, &1)) |> Enum.reject(&is_nil/1) |> Enum.sort()
    median = if known == [], do: 0, else: Enum.at(known, div(length(known), 2))

    files
    |> Enum.map(&{Map.get(ms, &1, median), &1})
    |> Enum.sort_by(fn {t, f} -> {-t, f} end)
    |> Enum.reduce(Map.new(1..n, &{&1, {0, []}}), fn {t, f}, acc ->
      {k, {sum, fs}} = Enum.min_by(acc, fn {k, {sum, _}} -> {sum, k} end)
      Map.put(acc, k, {sum + t, [f | fs]})
    end)
    |> Map.fetch!(i)
    |> elem(1)
    |> Enum.sort()
  end
end
