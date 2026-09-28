defmodule LoopctlRunner.PendingVerdicts do
  @moduledoc """
  Triage verdict messages that have been pushed and not yet settled, kept on disk so a Control
  that dies before the acknowledgement still delivers them: `<run_dir>/verdict_message.json`, the
  message exactly as it was built.

  Shaped like `LoopctlRunner.PendingStarts`, and stored in the run directory rather than in a
  directory of its own because that is where everything else about the run already is — the
  verdict the session wrote, the trace, the state naming the dispatch — and a message whose run
  directory is gone has nothing left to report about.

  THE BYTES ARE KEPT, NOT THE MATERIALS TO REBUILD THEM. loopctl answers a resend of the same
  message `ok` with `replayed` true, and refuses a DIFFERENT verdict for the same dispatch
  `already_recorded`, permanently. Re-deriving a message from `verdict.json` and `state.json` at
  restart would be one refactor away from producing different bytes, and the run's only output
  would then be discarded by the very mechanism meant to save it.

  A file is written by whoever STATES the outcome, before anything is told about it, and deleted
  when loopctl has recorded it or the refusal is one no resend can move. What is left behind is
  therefore exactly what is still owed. There are two staters and they cover disjoint cases:

    * `LoopctlRunner.TriageRun` at the end of every run, which is what survives a run that
      outlives every Control — its outcome reaches Control as a message, and a message reaches
      nobody when none is registered to take it;
    * `LoopctlRunner.Control` for an outcome it had to state ITSELF, which is the one case the run
      cannot record: its task died before it concluded anything.

  Where both write, the second is Control, and Control is the one that pushes — so the file ends
  up holding the bytes that went out, which is the invariant this store exists for.
  """

  require Logger

  alias LoopctlRunner.AtomicFile

  # NOT `@file`: that attribute is Elixir's own, set for the next definition and never read back.
  @message_file "verdict_message.json"

  @spec file(String.t()) :: String.t()
  def file(run_dir), do: Path.join(run_dir, @message_file)

  @doc "Records `payload` as owed, atomically (write-then-rename)."
  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(run_dir, payload) do
    AtomicFile.write(file(run_dir), JSON.encode!(payload))
  end

  @doc "Forgets a settled message; one already gone, or a run directory that is not, is fine."
  @spec delete(String.t() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(run_dir) do
    File.rm(file(run_dir))
    File.rm(resent_file(run_dir))
    :ok
  end

  # Contract 1.22.0: a verdict refused `stale_claim_epoch` is resent ONCE, with the same bytes,
  # before it is given up. That it was resent is recorded beside the message, and goes with it, so
  # a Control that starts over a message it already resent gives it up on the next such refusal
  # rather than resending it again. A marker of its own, never a field in the message file: that
  # file holds exactly the bytes that went out.
  @resent_file "verdict_message.resent"

  defp resent_file(run_dir), do: Path.join(run_dir, @resent_file)

  @doc "Records that the message owed for `run_dir` was resent after a `stale_claim_epoch`."
  @spec mark_resent(String.t() | nil) :: :ok | {:error, term()}
  def mark_resent(nil), do: :ok
  def mark_resent(run_dir), do: AtomicFile.write(resent_file(run_dir), "")

  @doc "Whether the message owed for `run_dir` was already resent after a `stale_claim_epoch`."
  @spec resent?(String.t() | nil) :: boolean()
  def resent?(nil), do: false
  def resent?(run_dir), do: File.exists?(resent_file(run_dir))

  @doc """
  The message owed for one run: `{:ok, payload}`, `:none`, or `{:error, reason}` when a file is
  there and cannot be read as one.

  The caller decides what an unreadable one means, because the two callers differ: the startup
  sweep keeps it (it is the only record of what that run concluded), while a run whose task just
  died has an outcome to fall back on.
  """
  @spec read(String.t() | nil) :: {:ok, map()} | :none | {:error, term()}
  def read(nil), do: :none

  def read(run_dir) do
    case File.read(file(run_dir)) do
      {:ok, raw} -> decode(raw)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, other} -> {:error, {:not_an_object, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every owed message under `runs_dir`, as `{run_dir, payload}`.

  A file that does not decode is logged and skipped: it cannot be sent, and nothing else about
  the run can be delivered in its place.
  """
  @spec all(String.t()) :: [{String.t(), map()}]
  def all(runs_dir) do
    runs_dir
    |> Path.join("*")
    |> Path.join(@message_file)
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, raw} <- File.read(path),
           {:ok, payload} when is_map(payload) <- JSON.decode(raw) do
        [{Path.dirname(path), payload}]
      else
        # Settled between the wildcard and the read — the common case for a caller watching this
        # list shrink — and nothing an operator needs to see.
        {:error, :enoent} ->
          []

        other ->
          Logger.error("verdict message file #{path} is unreadable (#{inspect(other)}); skipped")
          []
      end
    end)
  end
end
