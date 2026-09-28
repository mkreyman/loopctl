defmodule LoopctlRunner.WorktreeLock do
  @moduledoc """
  One live run per worktree path, enforced by an exclusively-created lock file.

  Every run of a story uses the same worktree path, so two runs started together would
  otherwise both find no holder in the registry and both run in one worktree. Linking the lock
  into place, which fails when one is there, is the atomic step a registry read followed by a
  write is not.

  A lock whose owner (`LoopctlRunner.Owner`) is dead is stale and is taken over, and so is one
  that will not read: a lock is LINKED into place already written, so no reader ever sees one
  mid-create, and a lock naming no one can protect no one — held, it would refuse its path for
  ever. Takeover renames the stale file aside first and checks it is the one that was judged
  stale, so two runs taking over together cannot delete each other's fresh lock.
  """

  alias LoopctlRunner.Owner

  @spec acquire(String.t(), String.t(), String.t()) :: :ok | {:error, {:held, String.t()}}
  def acquire(runs_dir, path, run_id) do
    lock = lock_path(runs_dir, path)
    File.mkdir_p!(Path.dirname(lock))
    body = JSON.encode!(Map.merge(Owner.current(), %{"run_id" => run_id, "path" => path}))

    case create(lock, body) do
      :ok -> :ok
      {:error, :eexist} -> take_over_if_stale(lock, body, runs_dir, path)
    end
  end

  # Written whole under a private name, then hard-linked to the lock path, which fails with
  # `:eexist` as atomically as an `O_EXCL` create does — but the file it publishes is already
  # complete, so an unreadable lock is corruption and never a writer caught half-way.
  defp create(lock, body) do
    tmp = lock <> ".new-#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp, body)
      link(tmp, lock)
    after
      File.rm(tmp)
    end
  end

  defp link(tmp, lock) do
    case File.ln(tmp, lock) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :eexist}
      {:error, reason} -> raise File.LinkError, reason: reason, existing: tmp, new: lock
    end
  end

  @doc """
  `acquire/3` for a caller that must never raise over a lock: the lock directory that cannot be
  created, a lock file that cannot be written. `{:error, {:unavailable, reason}}` for those, so the
  boot-time reaper skips one orphan rather than taking down the run that called it.
  """
  @spec try_acquire(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:held, String.t()}} | {:error, {:unavailable, String.t()}}
  def try_acquire(runs_dir, path, run_id) do
    acquire(runs_dir, path, run_id)
  rescue
    error -> {:error, {:unavailable, Exception.message(error)}}
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
      {:ok, %{"run_id" => holder} = held} = judged ->
        if Owner.alive?(held),
          do: {:error, {:held, holder}},
          else: replace_stale(lock, judged, body, runs_dir, path)

      # Unreadable, which since `create/2` links a lock in whole can only be a corrupt file: it
      # names no live owner, so it is stale.
      judged ->
        replace_stale(lock, judged, body, runs_dir, path)
    end
  end

  # `judged` is the read that found the lock stale; the file moved aside must read the same, or a
  # fresh lock landed between the two and is put back.
  defp replace_stale(lock, judged, body, runs_dir, path) do
    aside = lock <> ".stale-#{System.unique_integer([:positive])}"

    with :ok <- File.rename(lock, aside),
         ^judged <- read(aside) do
      File.rm(aside)

      case create(lock, body) do
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
