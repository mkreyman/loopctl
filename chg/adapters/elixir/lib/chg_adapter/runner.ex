defmodule ChgAdapter.Runner do
  @moduledoc "Runs `mix test` on a list of test paths and turns the results into a contract document."

  @doc """
  Runs `paths` (`file` or `file:line`) and prints `{"results":[…]}`. A path that produced
  no result, because it failed to load or the run crashed first, is reported as an
  `error` when the run failed and a `skip` when it passed (every test excluded).
  """
  def run(paths, allow_empty?) do
    ChgAdapter.preload!()
    {present, absent} = Enum.split_with(paths, &File.regular?(file_of(&1)))

    results_file =
      Path.join(System.tmp_dir!(), "chg-results-#{System.unique_integer([:positive])}.jsonl")

    System.put_env("CHG_RESULTS", results_file)
    if present != [], do: ChgAdapter.TestDb.reset_ahead()
    recording = start_recording(present)
    status = if present == [], do: 0, else: mix_test(present)
    results = read(results_file)
    File.rm(results_file)
    stop_recording(recording, results)

    results =
      results ++
        missing(present, results, status, allow_empty? or absent != []) ++
        Enum.map(absent, &%{id: &1, status: "error", ms: 0})

    failed? = Enum.any?(results, &(&1.status in ["fail", "error"]))
    ChgAdapter.emit(%{results: results})
    ChgAdapter.halt(if failed?, do: 1, else: 0)
  end

  # With `CHG_RECORD` set (the verifier's full run), the run also writes a coverage record
  # there. Recording never changes the verdict: a record that cannot be made is reported
  # on stderr and not written.
  defp start_recording([]), do: nil

  defp start_recording(_present) do
    with path when is_binary(path) and path != "" <- System.get_env("CHG_RECORD"),
         {:ok, sha} <- clean_head() do
      ChgAdapter.compile!()
      {:ok, graph} = ChgAdapter.Graph.read()
      modules = graph.source_modules |> Map.values() |> List.flatten() |> Enum.uniq()
      %{path: path, sha: sha, modules: modules, cover: ChgAdapter.Cover.start(modules)}
    else
      {:error, why} ->
        IO.puts(:standard_error, "chg: no coverage record: #{why}")
        nil

      _ ->
        nil
    end
  rescue
    e ->
      IO.puts(:standard_error, "chg: no coverage record: #{Exception.message(e)}")
      nil
  end

  defp stop_recording(nil, _results), do: :ok

  defp stop_recording(r, results) do
    %{cover: cover, global: global, reads: reads, global_reads: global_reads} =
      ChgAdapter.Cover.stop(r.cover)

    ms =
      Enum.reduce(results, %{}, fn t, acc ->
        Map.update(acc, file_of(t.id), t.ms, &(&1 + t.ms))
      end)

    ChgAdapter.Record.write!(r.path, %{
      sha: r.sha,
      digests: ChgAdapter.Digest.of_modules(r.modules),
      cover: cover,
      global: global,
      reads: reads,
      global_reads: global_reads,
      ms: ms
    })

    IO.puts(
      :standard_error,
      "chg: coverage record for #{r.sha}: #{map_size(cover)} test file(s), #{length(global)} module(s) used by every test"
    )
  rescue
    e -> IO.puts(:standard_error, "chg: no coverage record: #{Exception.message(e)}")
  end

  # The record names a commit, so the tree must be exactly it.
  defp clean_head do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=no"],
           stderr_to_stdout: true
         ) do
      {"", 0} -> ChgAdapter.resolve("HEAD")
      {_, 0} -> {:error, "the tree has uncommitted changes"}
      {out, _} -> {:error, "git status failed: #{String.trim(out)}"}
    end
  end

  # In this VM, so the preloaded formatter survives the code-path pruning `mix test`'s
  # compile does. `--raise` turns every failure `mix test` would otherwise defer to an
  # at-exit status into an exception here, so the exit status is ours to set.
  defp mix_test(paths) do
    args = [
      "--raise",
      "--formatter",
      "ExUnit.CLIFormatter",
      "--formatter",
      "ChgAdapter.Formatter"
    ]

    Mix.Task.run("test", args ++ paths)
    ChgAdapter.Formatter.sync()
    0
  rescue
    e ->
      ChgAdapter.Formatter.sync()
      IO.puts(:standard_error, "chg: mix test: " <> Exception.message(e))
      1
  catch
    :exit, reason ->
      ChgAdapter.Formatter.sync()
      IO.puts(:standard_error, "chg: mix test exited: " <> inspect(reason))
      1
  end

  defp read(file) do
    case File.read(file) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true) do
          m = JSON.decode!(line)
          %{id: m["id"], status: m["status"], ms: m["ms"]}
        end

      {:error, _} ->
        []
    end
  end

  @doc false
  # Results for paths `mix test` reported nothing for. A non-zero run with no failing
  # result (a test file that did not compile, a crash in the helper) is an `error`, so the
  # document agrees with the exit status; otherwise an unreported path ran no tests.
  def missing(paths, results, status, allow_empty?) do
    covered = MapSet.new(results, &file_of(&1.id))
    uncovered = Enum.reject(paths, &MapSet.member?(covered, file_of(&1)))
    failed? = Enum.any?(results, &(&1.status in ["fail", "error"]))

    extra =
      cond do
        status != 0 and not failed? and uncovered == [] ->
          [%{id: "mix test (exit #{status})", status: "error", ms: 0}]

        status != 0 and not failed? ->
          Enum.map(uncovered, &%{id: &1, status: "error", ms: 0})

        true ->
          Enum.map(uncovered, &%{id: &1, status: "skip", ms: 0})
      end

    if extra == [] and results == [] and not allow_empty?,
      do: [%{id: "(no tests)", status: "skip", ms: 0}],
      else: extra
  end

  defp file_of(id), do: id |> String.split(":") |> hd()
end
