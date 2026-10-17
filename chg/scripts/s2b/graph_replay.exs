# Replays ChgAdapter.Select over the last N first-parent PR merges of a Mix project's
# trunk, using ONE module graph and ONE test reference cache (the ones at HEAD).
#
#   cd <project> && MIX_ENV=test mix chg.refs
#   MIX_ENV=test mix run --no-start --no-compile <this file> <N> <timings.csv|-> <out.csv> [test_wall_s]
#
# Run it from the project's root (Mix loads the project from the working directory).
# <timings.csv> has `file,ms,...` rows (summed test time per test file, from one full run);
# `-` skips every time estimate. <test_wall_s> is that run's ExUnit "Finished in" time: a
# selection's seconds are its share of the summed ms times that wall, and its 4- and
# 8-shard times are the largest LPT (longest file first onto the least-loaded shard) bin,
# scaled the same way. Boot, compile and DB setup are excluded from all three.
# Writes one row per PR to <out.csv> and prints a summary.
#
# Approximations, all deliberate:
#   * The graph and refs are HEAD's, not each PR's base. A path a PR touched that is gone
#     at HEAD maps to nothing: it is "unmapped", not a fail-closed `all` (it existed when
#     the PR merged), and such PRs are counted under `stale`.
#   * always_all is the Elixir default list from design §3.13, applied before Select, as
#     `chg adapter exec affected` does.
#   * since_snapshot is empty: refs and graph are at the same revision.

# `mix compile` prunes the code path to the project's own apps, dropping the archive.
for ebin <- Path.wildcard(Path.join(Mix.path_for(:archives), "chg_adapter*/chg_adapter*/ebin")),
    do: Code.prepend_path(ebin)

ChgAdapter.preload!()

[n, timings_path, out, wall_s] =
  case System.argv() do
    [n, t, o] -> [String.to_integer(n), t, o, nil]
    [n, t, o, w] -> [String.to_integer(n), t, o, String.to_float(w)]
    _ -> raise "usage: replay.exs <N> <timings.csv|-> <out.csv> [test_wall_s]"
  end

always_all = ~w(mix.exs mix.lock config/** priv/repo/migrations/** test/test_helper.exs
                test/support/** .tool-versions .chg/**)

glob_match? = fn path, pat ->
  if String.ends_with?(pat, "/**"),
    do: String.starts_with?(path, String.trim_trailing(pat, "**")),
    else: path == pat
end

doc? = fn p -> String.ends_with?(p, ".md") or String.starts_with?(p, "docs/") end

git = fn args ->
  {out, 0} = System.cmd("git", args)
  out
end

{:ok, graph} = ChgAdapter.Graph.read()
{:ok, refs} = ChgAdapter.Refs.read()
test_files = ChgAdapter.test_files()
total = length(test_files)
unknown = Enum.count(test_files, &(not is_list(Map.get(refs.tests, &1))))

IO.puts(
  "graph: #{map_size(graph.source_modules)} sources, " <>
    "#{graph.source_modules |> Map.values() |> List.flatten() |> length()} modules; " <>
    "refs: #{map_size(refs.tests)} test files recorded, #{unknown} of #{total} without references"
)

timings =
  case timings_path do
    "-" ->
      nil

    path ->
      path
      |> File.stream!()
      |> Stream.drop(1)
      |> Map.new(fn line ->
        [f, ms | _] = line |> String.trim() |> String.split(",")
        {f, String.to_integer(ms)}
      end)
  end

total_ms = if timings, do: test_files |> Enum.map(&Map.get(timings, &1, 0)) |> Enum.sum()
ms_of = fn files -> if timings, do: files |> Enum.map(&Map.get(timings, &1, 0)) |> Enum.sum() end

lpt = fn files, k ->
  if timings do
    files
    |> Enum.map(&Map.get(timings, &1, 0))
    |> Enum.sort(:desc)
    |> Enum.reduce(List.duplicate(0, k), fn t, [low | rest] -> Enum.sort([low + t | rest]) end)
    |> Enum.max()
  end
end

secs = fn ms -> if ms && wall_s && total_ms > 0, do: Float.round(ms / total_ms * wall_s, 1) end

commits =
  git.(["log", "--first-parent", "--format=%H%x09%s", "HEAD"])
  |> String.split("\n", trim: true)
  |> Enum.map(&String.split(&1, "\t", parts: 2))
  |> Enum.filter(fn [_, s] -> Regex.match?(~r/\(#\d+\)\s*$/, s) end)
  |> Enum.take(n)

rows =
  for [sha, subject] <- commits do
    changed =
      git.(["diff", "--no-renames", "--name-only", sha <> "^", sha])
      |> String.split("\n", trim: true)

    hit =
      Enum.find_value(changed, fn p -> Enum.find(always_all, &glob_match?.(p, &1)) end)

    stale? = Enum.any?(changed, &(String.ends_with?(&1, ".ex") and not File.exists?(&1)))
    docs_only? = changed != [] and Enum.all?(changed, doc?)

    {mode, why, selected} =
      if hit do
        {"all", "always_all: " <> hit, test_files}
      else
        case ChgAdapter.Select.run(%{
               changed: changed,
               since_snapshot: [],
               graph: graph,
               refs: refs,
               test_files: test_files,
               test_file?: &ChgAdapter.test_file?/1,
               exists?: fn _ -> true end
             }) do
          {:subset, why, tests} -> {"subset", why, tests}
          {:all, why} -> {"all", "selector: " <> why, test_files}
        end
      end

    %{
      sha: sha,
      subject: subject,
      n_changed: length(changed),
      mode: mode,
      why: why,
      selected: length(selected),
      selected_ms: ms_of.(selected),
      lpt4_ms: lpt.(selected, 4),
      lpt8_ms: lpt.(selected, 8),
      stale: stale?,
      docs_only: docs_only?
    }
  end

csv_escape = fn s -> "\"" <> String.replace(to_string(s), "\"", "\"\"") <> "\"" end
wall_frac = fn r -> if total_ms && total_ms > 0, do: r.selected_ms / total_ms end

File.write!(
  out,
  [
    "sha,subject,n_changed,mode,why,selected,total,frac_files,frac_ms,est_s,est_4shard_s,est_8shard_s,stale,docs_only\n"
    | for r <- rows do
        Enum.join(
          [
            String.slice(r.sha, 0, 10),
            csv_escape.(r.subject),
            r.n_changed,
            r.mode,
            csv_escape.(r.why),
            r.selected,
            total,
            Float.round(r.selected / total, 4),
            (f = wall_frac.(r)) && Float.round(f, 4),
            secs.(r.selected_ms),
            secs.(r.lpt4_ms),
            secs.(r.lpt8_ms),
            r.stale,
            r.docs_only
          ],
          ","
        ) <> "\n"
      end
  ]
)

pct = fn xs, p ->
  s = Enum.sort(xs)
  Enum.at(s, min(length(s) - 1, round(p / 100 * (length(s) - 1))))
end

dist = fn label, rs, f ->
  xs = Enum.map(rs, f)

  IO.puts(
    "#{label} (n=#{length(xs)}): " <>
      Enum.map_join([10, 25, 50, 75, 90], " ", &"p#{&1}=#{Float.round(pct.(xs, &1) * 1.0, 3)}") <>
      " mean=#{Float.round(Enum.sum(xs) / max(length(xs), 1), 3)}"
  )
end

IO.puts("test files: #{total}; PRs: #{length(rows)}; total summed ms: #{inspect(total_ms)}")
code = Enum.reject(rows, & &1.docs_only)
dist.("files frac, all PRs", rows, &(&1.selected / total))
dist.("files frac, non-docs PRs", code, &(&1.selected / total))

if timings do
  dist.("time frac, all PRs", rows, wall_frac)
  dist.("time frac, non-docs PRs", code, wall_frac)
end

if timings && wall_s do
  IO.puts(
    "full suite: #{wall_s}s test wall; LPT 4 shards #{secs.(lpt.(test_files, 4))}s, 8 shards #{secs.(lpt.(test_files, 8))}s"
  )

  dist.("est s, all PRs", rows, &secs.(&1.selected_ms))
  dist.("est s, non-docs PRs", code, &secs.(&1.selected_ms))
  dist.("est s 4 shards, non-docs PRs", code, &secs.(&1.lpt4_ms))
  dist.("est s 8 shards, non-docs PRs", code, &secs.(&1.lpt8_ms))
end

all_rows = Enum.filter(rows, &(&1.mode == "all"))

IO.puts(
  "mode all: #{length(all_rows)} (always_all #{Enum.count(all_rows, &String.starts_with?(&1.why, "always_all"))}, " <>
    "selector #{Enum.count(all_rows, &String.starts_with?(&1.why, "selector"))}); " <>
    "docs-only: #{Enum.count(rows, & &1.docs_only)}; stale paths: #{Enum.count(rows, & &1.stale)}"
)

all_rows
|> Enum.frequencies_by(& &1.why)
|> Enum.sort_by(&(-elem(&1, 1)))
|> Enum.each(fn {why, c} -> IO.puts("  #{c}x #{why}") end)
