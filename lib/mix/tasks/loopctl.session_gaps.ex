defmodule Mix.Tasks.Loopctl.SessionGaps do
  @shortdoc "Measures the gaps between one session's tool calls in Claude Code transcripts"

  @moduledoc """
  The measurement behind the session holder's lease (US-52.19,
  `docs/factory/measurements/session-holder-lease.md`).

      mix loopctl.session_gaps HOST_DIR...

  Each `HOST_DIR` is one machine's transcripts: every `*.jsonl` under it, at any depth (a
  copy of `~/.claude/projects`, or the reduced extract the measurement doc describes). An
  entry counts when it carries a `sessionId`, a `timestamp` and a `message.content` list
  holding a `tool_use`; entries are grouped by `sessionId` and the gaps between one
  session's consecutive tool calls are measured in seconds.

  Prints one JSON object: per host directory (keyed by its basename) the session count, the
  gap count, the p50, p95, p99 and maximum gap, and how many gaps exceed 300 s and 3600 s;
  plus `skipped_lines`, the lines that were not JSON. A malformed line never ends the run.
  Percentiles are nearest-rank. Reads only; nothing leaves the machine.
  """

  use Mix.Task

  @impl Mix.Task
  def run(dirs), do: report(dirs, fn line -> Mix.shell().info(line) end)

  @doc false
  # Public for the test: the report for `dirs`, handed to `print` (the Mix shell in `run/1`).
  @spec report([Path.t()], (String.t() -> any())) :: any()
  def report(dirs, print) do
    if dirs == [], do: Mix.raise("usage: mix loopctl.session_gaps HOST_DIR...")

    {hosts, skipped} =
      Enum.map_reduce(dirs, 0, fn dir, skipped ->
        {stats, host_skipped} = measure_dir(dir)
        {{Path.basename(Path.expand(dir)), stats}, skipped + host_skipped}
      end)

    print.(Jason.encode!(%{hosts: Map.new(hosts), skipped_lines: skipped}, pretty: true))
  end

  @doc false
  # Public for the test: `{stats, skipped_lines}` for one host directory.
  @spec measure_dir(Path.t()) :: {map(), non_neg_integer()}
  def measure_dir(dir) do
    {by_session, skipped} =
      dir
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.reduce({%{}, 0}, fn file, acc ->
        file |> File.stream!() |> Enum.reduce(acc, &read_line/2)
      end)

    gaps =
      by_session
      |> Map.values()
      |> Enum.flat_map(fn stamps ->
        stamps
        |> Enum.sort()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)
      end)
      |> Enum.sort()

    {stats(map_size(by_session), gaps), skipped}
  end

  defp read_line(line, {sessions, skipped}) do
    case String.trim(line) do
      "" ->
        {sessions, skipped}

      text ->
        case Jason.decode(text) do
          {:ok, entry} -> {record(sessions, entry), skipped}
          {:error, _} -> {sessions, skipped + 1}
        end
    end
  end

  defp record(sessions, %{"sessionId" => id, "timestamp" => ts, "message" => %{"content" => c}})
       when is_binary(id) and is_binary(ts) and is_list(c) do
    with true <- Enum.any?(c, &match?(%{"type" => "tool_use"}, &1)),
         {:ok, at, _offset} <- DateTime.from_iso8601(ts) do
      Map.update(
        sessions,
        id,
        [DateTime.to_unix(at, :millisecond) / 1000],
        &[DateTime.to_unix(at, :millisecond) / 1000 | &1]
      )
    else
      _ -> sessions
    end
  end

  defp record(sessions, _entry), do: sessions

  defp stats(session_count, []),
    do: %{
      sessions: session_count,
      gaps: 0,
      p50: nil,
      p95: nil,
      p99: nil,
      max: nil,
      over_300: 0,
      over_3600: 0
    }

  defp stats(session_count, sorted) do
    %{
      sessions: session_count,
      gaps: length(sorted),
      p50: round1(rank(sorted, 50)),
      p95: round1(rank(sorted, 95)),
      p99: round1(rank(sorted, 99)),
      max: round1(List.last(sorted)),
      over_300: Enum.count(sorted, &(&1 > 300)),
      over_3600: Enum.count(sorted, &(&1 > 3600))
    }
  end

  defp round1(seconds), do: Float.round(seconds * 1.0, 1)

  # Nearest rank: the smallest value with at least p% of the values at or below it.
  defp rank(sorted, p) do
    index = max(ceil(p / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end
end
