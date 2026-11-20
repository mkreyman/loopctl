defmodule LoopctlRunner.PendingStarts do
  @moduledoc """
  Accepted dispatches whose run has not started yet, kept on disk so a Control restart does not
  forget them: `<runs_dir>/.pending/<dispatch_id>.json`, the dispatch as it arrived.

  A file is written when a dispatch is accepted and deleted when its run starts or its accept is
  finally refused. A Control that starts over a file resends the accept (loopctl answers an
  identical repeat `ok`) and starts the run on `ok`, exactly as for a fresh accept. The directory
  is hidden, so `LoopctlRunner.RunState.all/1` never mistakes it for a run.
  """

  require Logger

  alias LoopctlRunner.{AtomicFile, Uuid}

  @spec dir(String.t()) :: String.t()
  def dir(runs_dir), do: Path.join(runs_dir, ".pending")

  @doc "Records `dispatch` as pending, atomically (write-then-rename)."
  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(runs_dir, %{"dispatch_id" => id} = dispatch) do
    with {:ok, path} <- path(runs_dir, id),
         :ok <- File.mkdir_p(dir(runs_dir)) do
      AtomicFile.write(path, JSON.encode!(dispatch))
    end
  end

  @doc "Forgets a pending dispatch; one already gone is fine."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(runs_dir, id) do
    with {:ok, path} <- path(runs_dir, id), do: File.rm(path)
    :ok
  end

  @doc "Every pending dispatch on disk. A file that does not decode is logged and skipped."
  @spec all(String.t()) :: [map()]
  def all(runs_dir) do
    runs_dir
    |> dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, raw} <- File.read(path),
           {:ok, %{"dispatch_id" => id} = dispatch} when is_binary(id) <- JSON.decode(raw) do
        [dispatch]
      else
        other ->
          Logger.error("pending dispatch file #{path} is unreadable (#{inspect(other)}); skipped")
          []
      end
    end)
  end

  # The id is contract-validated as a UUID before it gets here; checked again because it names a
  # file.
  defp path(runs_dir, id) do
    if Uuid.valid?(id),
      do: {:ok, Path.join(dir(runs_dir), String.downcase(id) <> ".json")},
      else: {:error, :invalid_dispatch_id}
  end
end
