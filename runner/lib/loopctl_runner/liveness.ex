defmodule LoopctlRunner.Liveness do
  @moduledoc """
  Parking detection (design §8).

  NOT "no writes under `subagents/` in N minutes": that directory exists only when a
  session dispatches subagents, so it calls every healthy solo session parked from
  second zero (0 of 1,543 project directories on mac-mini had one).

  A session is ACTIVE when any of these shows activity inside the window:

    * bytes on the Port's stdout — the strongest signal, and it needs no filesystem;
    * the mtime of `<claude_projects_dir>/<slug>/<session_id>.jsonl`;
    * `claude agents --json` reporting the session `busy` (interactive rows) or
      `working` (background rows);
    * writes under `<slug>/<session_id>/subagents/` — kept only as a SUPPRESSOR meaning
      "legitimately waiting on a panel".

  PARKED requires positive evidence, never merely a quiet log: every signal above is
  quiet AND `claude agents` affirmatively reports the session not working (idle,
  blocked, done, or absent from the list). A failed probe is not evidence, so a
  session is never parked on silence plus a broken probe; the wall-clock budget is the
  backstop for that case.
  """

  @type agent_status :: :working | :idle | :absent | :unknown
  @type observation :: %{
          now_ms: integer(),
          last_stdout_ms: integer(),
          transcript_mtime_ms: integer() | nil,
          subagents_mtime_ms: integer() | nil,
          agent_status: agent_status()
        }
  @type verdict :: {:active, [atom()]} | {:quiet, [atom()]} | {:parked, map()}

  @doc """
  Pure verdict over one observation.

  `{:quiet, _}` means every file signal is quiet but the agents probe did not confirm
  parking — the caller keeps waiting.
  """
  @spec evaluate(observation(), pos_integer()) :: verdict()
  def evaluate(obs, window_ms) do
    active =
      [
        stdout: recent?(obs.now_ms, obs.last_stdout_ms, window_ms),
        transcript: recent?(obs.now_ms, obs.transcript_mtime_ms, window_ms),
        subagents: recent?(obs.now_ms, obs.subagents_mtime_ms, window_ms),
        agents: obs.agent_status == :working
      ]
      |> Enum.filter(fn {_signal, active?} -> active? end)
      |> Keyword.keys()

    cond do
      active != [] -> {:active, active}
      obs.agent_status in [:idle, :absent] -> {:parked, evidence(obs)}
      true -> {:quiet, [:agents_unconfirmed]}
    end
  end

  defp recent?(_now, nil, _window), do: false
  defp recent?(now, at, window), do: now - at < window

  defp evidence(obs) do
    %{
      "stdout_idle_ms" => obs.now_ms - obs.last_stdout_ms,
      "transcript_idle_ms" => idle(obs.now_ms, obs.transcript_mtime_ms),
      "subagents_idle_ms" => idle(obs.now_ms, obs.subagents_mtime_ms),
      "agent_status" => Atom.to_string(obs.agent_status)
    }
  end

  defp idle(_now, nil), do: nil
  defp idle(now, at), do: now - at

  @doc """
  The session's transcript and subagents mtimes, in ms since the epoch.

  The project slug is found by globbing for the session id rather than re-deriving the
  CLI's path-mangling rule, which is not a documented contract.
  """
  @spec file_signals(String.t(), String.t()) :: %{
          transcript_mtime_ms: integer() | nil,
          subagents_mtime_ms: integer() | nil
        }
  def file_signals(projects_dir, session_id) do
    case Path.wildcard(Path.join([projects_dir, "*", session_id <> ".jsonl"])) do
      [transcript | _] ->
        %{
          transcript_mtime_ms: mtime_ms(transcript),
          subagents_mtime_ms:
            newest_mtime_ms(Path.join([Path.dirname(transcript), session_id, "subagents"]))
        }

      [] ->
        %{transcript_mtime_ms: nil, subagents_mtime_ms: nil}
    end
  end

  defp mtime_ms(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime * 1000
      {:error, _} -> nil
    end
  end

  defp newest_mtime_ms(dir) do
    [dir | Path.wildcard(Path.join(dir, "**"), match_dot: true)]
    |> Enum.map(&mtime_ms/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  @doc "Asks `claude agents --json`, through the headless launcher, about one session."
  @spec agent_status(String.t(), String.t(), pos_integer()) :: agent_status()
  def agent_status(launcher, session_id, timeout_ms) do
    case LoopctlRunner.ProcessGroup.run(launcher, ["agents", "--json"], timeout_ms) do
      {:ok, out, 0} -> parse_agents(out, session_id)
      _ -> :unknown
    end
  end

  @doc false
  @spec parse_agents(binary(), String.t()) :: agent_status()
  def parse_agents(out, session_id) do
    case decode_array(out) do
      {:ok, rows} when is_list(rows) -> find_status(rows, session_id)
      _ -> :unknown
    end
  end

  defp find_status(rows, session_id) do
    case Enum.find(rows, &(is_map(&1) and &1["sessionId"] == session_id)) do
      nil -> :absent
      row -> row_status(row)
    end
  end

  # stderr is merged into the probe's output, so a warning line may precede the JSON.
  defp decode_array(out) do
    case :binary.match(out, "[") do
      {start, _} -> out |> binary_part(start, byte_size(out) - start) |> JSON.decode()
      :nomatch -> {:error, :no_json}
    end
  end

  defp row_status(%{"status" => "busy"}), do: :working
  defp row_status(%{"state" => "working"}), do: :working
  defp row_status(%{"status" => "idle"}), do: :idle
  defp row_status(%{"state" => state}) when state in ["blocked", "done"], do: :idle
  defp row_status(_), do: :unknown
end
