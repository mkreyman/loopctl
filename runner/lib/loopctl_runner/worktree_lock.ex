defmodule LoopctlRunner.WorktreeLock do
  @moduledoc """
  One live run per worktree path, enforced by an exclusively-created lock file.

  Every run of a story uses the same worktree path, so two runs started together would
  otherwise both find no holder in the registry and both run in one worktree. Creating the
  lock with `O_EXCL` is the atomic step a registry read followed by a write is not.

  A lock whose owner (`LoopctlRunner.Owner`) is dead is stale and is taken over. Takeover
  renames the stale file aside first and checks it is the one that was judged stale, so
  two runs taking over together cannot delete each other's fresh lock.
  """

  alias LoopctlRunner.Owner

  @spec acquire(String.t(), String.t(), String.t()) :: :ok | {:error, {:held, String.t()}}
  def acquire(runs_dir, path, run_id) do
    lock = lock_path(runs_dir, path)
    File.mkdir_p!(Path.dirname(lock))
    body = JSON.encode!(Map.merge(Owner.current(), %{"run_id" => run_id, "path" => path}))

    case File.write(lock, body, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> take_over_if_stale(lock, body, runs_dir, path)
    end
  end

  @doc "Releases the lock if, and only if, `run_id` holds it."
  @spec release(String.t(), String.t(), String.t()) :: :ok
  def release(runs_dir, path, run_id) do
    lock = lock_path(runs_dir, path)

    case read(lock) do
      {:ok, %{"run_id" => ^run_id}} -> File.rm(lock)
      _ -> :ok
    end

    :ok
  end

  @doc "The run id holding `path` on a live BEAM, or nil."
  @spec live_holder(String.t(), String.t()) :: String.t() | nil
  def live_holder(runs_dir, path) do
    case read(lock_path(runs_dir, path)) do
      {:ok, %{"run_id" => holder} = lock} -> if Owner.alive?(lock), do: holder
      _ -> nil
    end
  end

  defp take_over_if_stale(lock, body, runs_dir, path) do
    case read(lock) do
      {:ok, %{"run_id" => holder} = held} ->
        if Owner.alive?(held),
          do: {:error, {:held, holder}},
          else: replace_stale(lock, held, body, runs_dir, path)

      # Unreadable: a writer is mid-create, or the file is corrupt. Never guess it away.
      _ ->
        {:error, {:held, "unknown"}}
    end
  end

  defp replace_stale(lock, stale, body, runs_dir, path) do
    aside = lock <> ".stale-#{System.unique_integer([:positive])}"

    with :ok <- File.rename(lock, aside),
         {:ok, ^stale} <- read(aside) do
      File.rm(aside)

      case File.write(lock, body, [:exclusive]) do
        :ok -> :ok
        {:error, :eexist} -> acquire_held(runs_dir, path)
      end
    else
      _ ->
        # Someone else took it over first: put back whatever was moved, then report the holder.
        if File.exists?(aside), do: File.rename(aside, lock)
        acquire_held(runs_dir, path)
    end
  end

  defp acquire_held(runs_dir, path),
    do: {:error, {:held, live_holder(runs_dir, path) || "unknown"}}

  defp read(file) do
    with {:ok, raw} <- File.read(file), do: JSON.decode(raw)
  end

  defp lock_path(runs_dir, path) do
    digest = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    Path.join([runs_dir, "locks", digest <> ".lock"])
  end
end
