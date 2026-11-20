# Replays coverage selection (ChgAdapter.Select.by_coverage/1) over the PRs graph_replay.exs
# measured, with each PR judged against a record made at its own parent.
#
#   cd <project at HEAD, compiled in MIX_ENV=test>
#   MIX_ENV=test mix run --no-start --no-compile <this file> \
#     <record.cover> <digests dir> <per_pr.csv> <timings.csv> <test_wall_s> <out.csv> [relaxed glob...]
#
# <record.cover> is one full traced run at HEAD (its `cover` and `global`). <digests dir>
# holds `<sha>.etf` per commit from digests.exs (walk.sh). <per_pr.csv> is graph_replay.exs's
# output, whose rows name the PRs. Seconds are a selection's share of the summed ms times
# <test_wall_s>, as in graph_replay.exs. Each [relaxed glob] is dropped from always_all, to
# measure what coverage would select for paths it can see into.
#
# Approximations, all deliberate:
#   * The coverage map is HEAD's, not each parent's. A test file is keyed by path, so one that
#     did not exist at HEAD has no coverage and is selected when its PR changed it.
#   * The record is at the PR's parent (0 commits behind). A real gate's record is the newest
#     verified commit's, a few commits behind; the extra commits only add altered modules.
#   * The test files, test paths and @external_resource readers are HEAD's.

for ebin <- Path.wildcard(Path.join(Mix.path_for(:archives), "chg_adapter*/chg_adapter*/ebin")),
    do: Code.prepend_path(ebin)

ChgAdapter.preload!()

[record_path, digests_dir, per_pr, timings_path, wall_s, out | relaxed] = System.argv()
wall_s = String.to_float(wall_s)

always_all =
  ~w(mix.exs mix.lock config/** priv/repo/migrations/** test/test_helper.exs
     test/support/** .tool-versions .chg/**) -- relaxed

glob_match? = fn path, pat ->
  if String.ends_with?(pat, "/**"),
    do: String.starts_with?(path, String.trim_trailing(pat, "**")),
    else: path == pat
end

git = fn args ->
  {out, 0} = System.cmd("git", args)
  String.trim(out)
end

full = record_path |> File.read!() |> :erlang.binary_to_term()
{:ok, graph} = ChgAdapter.Graph.read()
test_files = ChgAdapter.test_files()
total = length(test_files)

timings =
  timings_path
  |> File.stream!()
  |> Stream.drop(1)
  |> Map.new(fn line ->
    [f, ms | _] = line |> String.trim() |> String.split(",")
    {f, String.to_integer(ms)}
  end)

total_ms = test_files |> Enum.map(&Map.get(timings, &1, 0)) |> Enum.sum()
ms_of = fn files -> files |> Enum.map(&Map.get(timings, &1, 0)) |> Enum.sum() end
secs = fn ms -> if ms && total_ms > 0, do: Float.round(ms / total_ms * wall_s, 1) end

lpt = fn files, k ->
  files
  |> Enum.map(&Map.get(timings, &1, 0))
  |> Enum.sort(:desc)
  |> Enum.reduce(List.duplicate(0, k), fn t, [low | rest] -> Enum.sort([low + t | rest]) end)
  |> Enum.max()
end

digests = fn sha ->
  case File.read(Path.join(digests_dir, sha <> ".etf")) do
    {:ok, bin} -> :erlang.binary_to_term(bin)
    _ -> nil
  end
end

prs =
  per_pr
  |> File.stream!()
  |> Stream.drop(1)
  |> Enum.map(fn line -> line |> String.split(",", parts: 2) |> hd() end)

IO.puts(
  "record: #{map_size(full.cover)} test files covered, #{length(full.global)} global modules, " <>
    "#{map_size(full.digests)} modules; always_all: #{Enum.join(always_all, " ")}"
)

rows =
  for short <- prs do
    sha = git.(["rev-parse", short])
    parent = git.(["rev-parse", sha <> "^1"])
    changed = git.(["diff", "--no-renames", "--name-only", parent, sha]) |> String.split("\n", trim: true)
    hit = Enum.find_value(changed, fn p -> Enum.find(always_all, &glob_match?.(p, &1)) end)

    {mode, why, selected, altered} =
      if hit do
        {"all", "always_all: " <> hit, test_files, nil}
      else
        now = digests.(sha)
        before = digests.(parent)

        if now == nil or before == nil do
          {"all", "no digests (a commit did not compile)", test_files, nil}
        else
          impls = MapSet.new(now.impls)

          case ChgAdapter.Select.by_coverage(%{
                 changed: changed,
                 since_record: [],
                 record: %{full | sha: parent, digests: before.digests} |> Map.put(:age, 0),
                 digests: now.digests,
                 graph: graph,
                 test_files: test_files,
                 test_file?: &ChgAdapter.test_file?/1,
                 test_path?: &ChgAdapter.test_path?/1,
                 impl?: &MapSet.member?(impls, &1)
               }) do
            {:subset, why, tests} ->
              n =
                Enum.count(now.digests, fn {m, d} -> Map.get(before.digests, m) != d end) +
                  Enum.count(before.digests, fn {m, _} -> not Map.has_key?(now.digests, m) end)

              {"subset", why, tests, n}

            {:all, why} ->
              {"all", "selector: " <> why, test_files, nil}
          end
        end
      end

    %{
      sha: String.slice(sha, 0, 10),
      mode: mode,
      why: why,
      altered: altered,
      selected: length(selected),
      ms: ms_of.(selected),
      lpt4: lpt.(selected, 4),
      lpt8: lpt.(selected, 8)
    }
  end

csv = fn s -> "\"" <> String.replace(to_string(s), "\"", "\"\"") <> "\"" end

File.write!(out, [
  "sha,mode,why,altered,selected,total,frac_ms,est_s,est_4shard_s,est_8shard_s\n"
  | for r <- rows do
      Enum.join(
        [
          r.sha,
          r.mode,
          csv.(r.why),
          r.altered,
          r.selected,
          total,
          Float.round(r.ms / total_ms, 4),
          secs.(r.ms),
          secs.(r.lpt4),
          secs.(r.lpt8)
        ],
        ","
      ) <> "\n"
    end
])

pct = fn xs, p ->
  s = Enum.sort(xs)
  Enum.at(s, min(length(s) - 1, round(p / 100 * (length(s) - 1))))
end

dist = fn label, xs ->
  IO.puts(
    "#{label} (n=#{length(xs)}): " <>
      Enum.map_join([10, 25, 50, 75, 90], " ", &"p#{&1}=#{Float.round(pct.(xs, &1) * 1.0, 3)}")
  )
end

subset = Enum.filter(rows, &(&1.mode == "subset"))
IO.puts("full suite: #{wall_s}s; LPT 4 shards #{secs.(lpt.(test_files, 4))}s, 8 shards #{secs.(lpt.(test_files, 8))}s")
dist.("files frac, all PRs", Enum.map(rows, &(&1.selected / total)))
dist.("time frac, all PRs", Enum.map(rows, &(&1.ms / total_ms)))
dist.("time frac, subset PRs", Enum.map(subset, &(&1.ms / total_ms)))
dist.("est s, all PRs", Enum.map(rows, &secs.(&1.ms)))
dist.("est s 4 shards, all PRs", Enum.map(rows, &secs.(&1.lpt4)))
dist.("est s 8 shards, all PRs", Enum.map(rows, &secs.(&1.lpt8)))
dist.("altered modules, subset PRs", Enum.map(subset, & &1.altered))

rows
|> Enum.reject(&(&1.mode == "subset"))
|> Enum.frequencies_by(&(&1.why |> String.split(" changed,") |> hd()))
|> Enum.sort_by(&(-elem(&1, 1)))
|> Enum.each(fn {why, c} -> IO.puts("  #{c}x #{why}") end)
