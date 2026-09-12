defmodule LoopctlRunner.Owner do
  @moduledoc """
  The identity of the BEAM that recorded a run or holds a lock.

  A pid alone is not an identity: once a runner dies its pid is reused, and on a dev
  machine the next BEAM (a dev server, elixir-ls, a test run) is a likely taker. A stale
  "owner alive" answer is not harmless — it blocks every later run of that story. So an
  owner is the os pid AND that process's start time, which a reused pid cannot match.
  """

  @type t :: %{required(String.t()) => term()}

  @doc "This BEAM's identity."
  @spec current() :: t()
  def current do
    pid = String.to_integer(System.pid())
    %{"beam_os_pid" => pid, "beam_started" => started(pid)}
  end

  @doc "True when the recorded owner is still the same running process."
  @spec alive?(map()) :: boolean()
  def alive?(%{"beam_os_pid" => pid, "beam_started" => started})
      when is_integer(pid) and is_binary(started) do
    started(pid) == started
  end

  def alive?(_), do: false

  # `ps -o lstart=` prints a fixed-format start time on both procps and BSD ps.
  defp started(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end
end
