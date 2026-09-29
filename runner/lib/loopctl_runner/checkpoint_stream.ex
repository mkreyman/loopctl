defmodule LoopctlRunner.CheckpointStream do
  @moduledoc """
  The commits a thread session pushed, reported to loopctl as `checkpoint`s (contract 1.20.0),
  which its merge executor merges.

  The source is what `priv/bin/loop-push` RECORDS, never a read of git: after each push it
  appends one line, `<commit_sha> <tree_sha>`, to `checkpoints.log` in the run's directory
  (`LOOP_RUN_DIR`). So only what the session itself pushed is reported, in the order it pushed
  it — never a base update loopctl's App merged into the branch, and never what a branch held
  before this run.

  Progress lives beside the log, in `checkpoints.sent`: how many lines are settled, or that the
  claim is over. A restart resumes there, and a line sent twice is harmless, because loopctl
  answers an identical resend `ok, replayed: true`. `Control` does the pushing and the timing;
  this module reads, writes the progress, and says what a reply means.
  """

  alias LoopctlRunner.{AtomicFile, ClaimEnded, Contract, RunState, Uuid}

  @log "checkpoints.log"
  @sent "checkpoints.sent"

  # The log is written by the session's loop-push, one short line per push. A file past this is
  # not one loop-push wrote, and is not read.
  @max_log_bytes 4 * 1024 * 1024

  # `sent` lines, `bytes` long, are settled. `line` is the next line's byte length and `later?`
  # whether a complete line follows it, both filled by `next/1`.
  @type run :: %{
          run_dir: String.t(),
          dispatch_id: String.t(),
          claim_epoch: non_neg_integer(),
          sent: non_neg_integer(),
          bytes: non_neg_integer(),
          line: non_neg_integer(),
          later?: boolean()
        }

  @doc "The log `loop-push` appends to, in `run_dir`."
  @spec log_path(String.t()) :: String.t()
  def log_path(run_dir), do: Path.join(run_dir, @log)

  @doc """
  The run directories under `runs_dir` that hold a log, with their state: the one scan of every
  `state.json`, which `Control` repeats only on a poll and `runs/2` narrows on every step.
  """
  @spec candidates(String.t()) :: [{String.t(), map()}]
  def candidates(runs_dir),
    do:
      for(
        {run_dir, state} <- RunState.all(runs_dir),
        File.regular?(log_path(run_dir)),
        do: {run_dir, state}
      )

  @doc """
  Runs with something for `next/1` to act on: bound to a dispatch whose claim is not recorded over
  (`LoopctlRunner.ClaimEnded`), whose checkpoints are not stopped, and whose log is longer than
  what is settled. A settled run costs a small read of its `checkpoints.sent` and a `stat` of its
  log, never a read of the log. A log that cannot be read or is too big is found too, so `next/1`
  can say so.
  """
  @spec runs(String.t(), [{String.t(), map()}]) :: [run()]
  def runs(runs_dir, candidates) do
    for {run_dir, state} <- candidates,
        not ClaimEnded.ended?(runs_dir, state),
        run = bound(run_dir, state),
        run != nil,
        pending?(run),
        do: run
  end

  @doc "The same, from a fresh scan of `runs_dir`."
  @spec runs(String.t()) :: [run()]
  def runs(runs_dir), do: runs(runs_dir, candidates(runs_dir))

  @doc """
  Whether `run_dir` holds a complete line loop-push recorded that is neither settled nor stopped,
  in a run bound to a dispatch, so one `runs/2` would report: what the run's end reports wait for.
  """
  @spec unsettled?(String.t()) :: boolean()
  def unsettled?(run_dir) do
    with {:ok, %{} = state} <- RunState.read(run_dir),
         %{bytes: bytes} <- bound(run_dir, state) do
      match?({:ok, [_ | _]}, tail(run_dir, bytes))
    else
      _ -> false
    end
  end

  defp bound(run_dir, %{"dispatch_id" => id, "claim_epoch" => epoch})
       when is_binary(id) and is_integer(epoch) and epoch >= 0 do
    if Uuid.valid?(id) and File.regular?(log_path(run_dir)) do
      case read_sent(run_dir) do
        {:sent, n, bytes} ->
          %{
            run_dir: run_dir,
            dispatch_id: id,
            claim_epoch: epoch,
            sent: n,
            bytes: bytes,
            line: 0,
            later?: false
          }

        :stopped ->
          nil
      end
    end
  end

  defp bound(_run_dir, _state), do: nil

  defp pending?(run) do
    case File.stat(log_path(run.run_dir)) do
      {:ok, %File.Stat{size: size}} -> size > run.bytes
      {:error, _} -> true
    end
  end

  # What is settled, against the log as it is now. A log shorter than what is settled is not the
  # one it was settled against (loop-push only appends): it is read as new, from its start.
  defp read_sent(run_dir) do
    case {progress(run_dir), File.stat(log_path(run_dir))} do
      {{:sent, _n, bytes}, {:ok, %File.Stat{size: size}}} when size < bytes -> {:sent, 0, 0}
      {progress, _stat} -> progress
    end
  end

  defp progress(run_dir) do
    case File.read(Path.join(run_dir, @sent)) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, %{"sent" => n, "bytes" => b}}
          when is_integer(n) and n >= 0 and is_integer(b) and b >= 0 ->
            {:sent, n, b}

          {:ok, %{"stopped" => _}} ->
            :stopped

          _ ->
            {:sent, 0, 0}
        end

      {:error, _} ->
        {:sent, 0, 0}
    end
  end

  # The first two COMPLETE lines after the first `bytes`, which is all `next/1` needs (the next line,
  # and whether another follows); read a block at a time, never the whole tail. loop-push's append
  # may be read half-written, and its tail waits for the next read.
  defp tail(run_dir, bytes) do
    path = log_path(run_dir)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_log_bytes ->
        {:stop, "#{@log} is #{size} bytes, more than loop-push ever writes"}

      {:ok, %File.Stat{size: size}} when size >= bytes ->
        case read_lines(path, bytes, size) do
          {:ok, raw} -> {:ok, raw |> String.split("\n") |> Enum.drop(-1) |> Enum.take(2)}
          {:error, reason} -> {:error, "cannot read #{@log}: #{:file.format_error(reason)}"}
        end

      {:ok, %File.Stat{}} ->
        {:error, "#{@log} changed while it was read"}

      {:error, reason} ->
        {:error, "cannot read #{@log}: #{:file.format_error(reason)}"}
    end
  end

  @block 4096

  # From `offset` up to `size`, a block at a time, until two line ends have been read.
  defp read_lines(path, offset, size) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        read_blocks(io, offset, size, "")
      after
        File.close(io)
      end
    end
  end

  defp read_blocks(io, offset, size, acc) do
    if offset >= size or line_ends(acc) >= 2 do
      {:ok, acc}
    else
      case :file.pread(io, offset, min(@block, size - offset)) do
        {:ok, data} -> read_blocks(io, offset + byte_size(data), size, acc <> data)
        :eof -> {:ok, acc}
        {:error, _} = error -> error
      end
    end
  end

  defp line_ends(data), do: data |> :binary.matches("\n") |> length()

  @doc """
  The `RunnerCheckpoint` for `run`'s next unsettled line, validated against the contract, with
  `run` updated to say how long that line is and whether another follows; `{:skip, why, run}` for
  a line that is not one loop-push writes, which is settled unsent; `:none` when every complete
  line is settled; `{:error, why}` when the log cannot be read now, and `{:stop, why}` when it is
  not one loop-push wrote at all.
  """
  @spec next(run()) ::
          {:ok, map(), run()} | {:skip, String.t(), run()} | {:error | :stop, String.t()} | :none
  def next(run) do
    case tail(run.run_dir, run.bytes) do
      {:ok, [line | rest]} ->
        run = %{run | line: byte_size(line) + 1, later?: rest != []}
        payload(run, line)

      {:ok, []} ->
        :none

      error ->
        error
    end
  end

  defp payload(run, line) do
    with [commit, tree] <- String.split(line, " "),
         payload = %{
           "dispatch_id" => run.dispatch_id,
           "claim_epoch" => run.claim_epoch,
           "commit_sha" => commit,
           "tree_sha" => tree
         },
         :ok <- Contract.validate("RunnerCheckpoint", payload) do
      {:ok, payload, run}
    else
      {:error, errors} ->
        {:skip, "line #{run.sent + 1} is not a checkpoint: #{inspect(errors)}", run}

      _ ->
        {:skip, "line #{run.sent + 1} is not `<commit_sha> <tree_sha>`", run}
    end
  end

  @doc "Records that `run`'s line, the one `next/1` returned, is settled."
  @spec settle(run()) :: :ok | {:error, File.posix()}
  def settle(run) do
    progress = %{"sent" => run.sent + 1, "bytes" => run.bytes + run.line}
    AtomicFile.write(Path.join(run.run_dir, @sent), JSON.encode!(progress))
  end

  @doc "Records that `run`'s claim is over, so nothing more of its log is sent."
  @spec stop(run(), String.t()) :: :ok | {:error, File.posix()}
  def stop(run, reason),
    do: AtomicFile.write(Path.join(run.run_dir, @sent), JSON.encode!(%{"stopped" => reason}))

  @doc """
  What a reply to a `checkpoint` means:

    * `:recorded` — settled;
    * `{:claim_over, reason}` — the claim is over (`x-connection.claim_ending_errors`): stop;
    * `{:not_accepted, reason}` — `dispatch_not_accepted`, whose meaning turns on whether this
      runner's accept is still outstanding, which only `Control` knows;
    * `{:refused, reason}` — any other permanent refusal: those bytes will never be taken, so the
      line is settled unsent and the next goes;
    * `{:rate_limited, refusal}` — wait the interval the refusal names, which `Control` bounds;
    * `{:transient, reason}` — anything else: try again later.
  """
  @spec classify(term()) ::
          :recorded
          | {:claim_over | :not_accepted | :refused | :transient, String.t()}
          | {:rate_limited, map()}
  def classify({:ok, _body}), do: :recorded
  def classify(:ok), do: :recorded

  def classify({:error, %{"reason" => reason} = refusal}) when is_binary(reason) do
    cond do
      reason in Contract.claim_ending_errors("checkpoint") -> {:claim_over, reason}
      # A lease that lapsed may be renewed: the line waits, backing off, and nothing behind it is
      # sent to be refused the same way.
      reason == "claim_not_live" -> {:transient, reason}
      reason == "dispatch_not_accepted" -> {:not_accepted, reason}
      reason == "rate_limited" -> {:rate_limited, refusal}
      reason in Contract.permanent_errors("checkpoint") -> {:refused, reason}
      true -> {:transient, reason}
    end
  end

  def classify(other), do: {:transient, "unrecognised reply #{inspect(other)}"}
end
