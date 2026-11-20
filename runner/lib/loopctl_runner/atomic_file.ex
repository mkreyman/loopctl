defmodule LoopctlRunner.AtomicFile do
  @moduledoc """
  Write-then-rename, the one way this runner replaces a file a reader may be reading: the content
  goes to a temporary file in the SAME directory — so the rename is within one filesystem, and
  atomic — and is renamed over the target. A reader sees the old bytes or the new ones, never a
  half-written file. The temporary name is unique, because two writers may replace one file at
  once (another run's take-over updating a `state.json`, say), and it is removed when either step
  fails, so a failed write leaves nothing behind.
  """

  @doc "Replaces `path` with `content`: `:ok`, or `{:error, reason}` with nothing left behind."
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, content) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp)
        error
    end
  end

  @doc "`write/2`, raising `File.Error` when it fails."
  @spec write!(Path.t(), iodata()) :: :ok
  def write!(path, content) do
    case write(path, content) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write atomically", path: path
    end
  end
end
