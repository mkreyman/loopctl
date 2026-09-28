defmodule LoopctlRunner.ClaimEnded do
  @moduledoc """
  That loopctl ended a claim (contract 1.22.0, `claim_ending_errors`): ONE marker per claim,
  `<runs_dir>/.claims/<dispatch_id>-<claim_epoch>`, written when the refusal arrives whether or
  not a run of the claim has a directory yet, and read by name.

  Everything that must honour the end reads it: a run immediately before it starts its session
  (`LoopctlRunner.Run`, `LoopctlRunner.TriageRun`, `LoopctlRunner.ReviewRun`), so a claim that
  ended before its session existed never starts one; a Control starting over, which stops any
  session of such a claim still running (`all/1`); and what would otherwise send that dispatch's
  work — a restarted stream, a triage verdict.

  The directory begins with a dot, so nothing listing runs (`*/state.json`) sees it. A
  `dispatch_id` that is not a UUID, or an epoch that is not a non-negative integer, names no
  marker: they come from the wire, and become a file name.
  """

  alias LoopctlRunner.{AtomicFile, Uuid}

  @dir ".claims"

  @doc "Records that the claim `epoch` of `dispatch_id` is over, and why."
  @spec record(String.t(), term(), term(), String.t(), String.t()) :: :ok | {:error, term()}
  def record(runs_dir, dispatch_id, epoch, event, reason) do
    with {:ok, path} <- path(runs_dir, dispatch_id, epoch),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      AtomicFile.write(path, JSON.encode!(%{"event" => event, "reason" => reason}))
    end
  end

  @doc "Whether the claim `epoch` of `dispatch_id` was recorded over."
  @spec ended?(String.t(), term(), term()) :: boolean()
  def ended?(runs_dir, dispatch_id, epoch) do
    case path(runs_dir, dispatch_id, epoch) do
      {:ok, path} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  @doc "The same, for a run's binding (`dispatch_id` and `claim_epoch`); a run with none, false."
  @spec ended?(String.t(), map()) :: boolean()
  def ended?(runs_dir, %{"dispatch_id" => id, "claim_epoch" => epoch}),
    do: ended?(runs_dir, id, epoch)

  def ended?(_runs_dir, _binding), do: false

  @doc "Every claim recorded over, as `{dispatch_id, claim_epoch}`."
  @spec all(String.t()) :: [{String.t(), non_neg_integer()}]
  def all(runs_dir) do
    case File.ls(Path.join(runs_dir, @dir)) do
      {:ok, names} -> for name <- names, {:ok, claim} <- [parse(name)], do: claim
      {:error, _} -> []
    end
  end

  @doc """
  Removes every marker older than `max_age_s` at `now` (both passed in), and returns how many.
  A claim's end matters only while a run of that claim could still start or report: loopctl
  dispatches again under a NEW epoch, so a marker outlives its use within hours, and one that is
  never removed is listed by every Control start for ever.
  """
  @spec prune(String.t(), integer(), pos_integer()) :: non_neg_integer()
  def prune(runs_dir, now_s, max_age_s) do
    dir = Path.join(runs_dir, @dir)

    case File.ls(dir) do
      {:ok, names} ->
        Enum.count(names, fn name ->
          path = Path.join(dir, name)

          match?(
            {:ok, %File.Stat{mtime: mtime}} when now_s - mtime > max_age_s,
            File.stat(path, time: :posix)
          ) and
            File.rm(path) == :ok
        end)

      {:error, _} ->
        0
    end
  end

  # A UUID holds dashes of its own, so the epoch is what follows the LAST one.
  defp parse(name) do
    with [epoch, id] <- name |> String.split("-") |> Enum.reverse() |> then(&split_last/1),
         true <- Uuid.valid?(id),
         {epoch, ""} when epoch >= 0 <- Integer.parse(epoch) do
      {:ok, {id, epoch}}
    else
      _ -> :error
    end
  end

  defp split_last([epoch | rest]) when rest != [],
    do: [epoch, rest |> Enum.reverse() |> Enum.join("-")]

  defp split_last(_parts), do: :error

  defp path(runs_dir, dispatch_id, epoch) do
    if Uuid.valid?(dispatch_id) and is_integer(epoch) and epoch >= 0,
      do: {:ok, Path.join([runs_dir, @dir, "#{dispatch_id}-#{epoch}"])},
      else: {:error, :not_a_claim}
  end
end
