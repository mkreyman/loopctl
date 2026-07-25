defmodule Loopctl.Secrets.LocalFileAdapter do
  @moduledoc """
  File-backed `Loopctl.Secrets.Behaviour` for SELF-HOSTED, single-machine installs
  that are not on Fly (#496). Select it in `config/runtime.exs` with
  `SECRETS_ADAPTER=local_file`; the file path defaults to `SECRETS_FILE` (see
  `runtime.exs`).

  Secrets (currently only the per-tenant audit signing private keys) are stored as a
  single JSON object `{name => base64(value)}` on disk.

  ## Atomicity, permissions, and durability

  Writes are ATOMIC — a sibling temp file is written then `rename/2`d over the target
  (a same-directory rename is atomic on POSIX), so a crash mid-write never leaves a
  torn file. The temp file is created and `chmod 0600` (owner read/write only) BEFORE
  any secret bytes are written into it, and the containing directory is `chmod 0700`,
  so at no point is a file holding secret material group/other-readable.

  For DURABILITY the temp file is `fsync`'d before the rename, so a committed secret's
  bytes reach stable storage before it becomes the live file. Note that fsync of the
  parent DIRECTORY (which is what guarantees the rename itself survives a power loss)
  is NOT reachable from the BEAM — `:file.open/2` on a directory returns `:eisdir` —
  so on a hard crash immediately after a rename the directory entry may, on some
  filesystems, revert to the pre-rename state. Keep the file on a journaled filesystem
  and backed up (see the threat model below).

  A hard crash BETWEEN creating the temp file and the rename leaks a `<path>.tmp.<n>`
  sibling (the same-invocation error path never runs on a SIGKILL/power loss). To bound
  that accumulation, each write first sweeps any orphaned `.tmp.` siblings — safe
  because it runs under the write lock, so no concurrent write owns a temp file.

  ## Threat model — read before using in production

  This is for a TRUSTED, SINGLE-MACHINE deployment (one operator, one host). Secret
  VALUES are base64 (encoding, NOT encryption): anyone who can read the file as the
  app user, or who has root, reads the raw keys. That is the SAME exposure as Fly's
  own model, where secrets are injected as plaintext process env vars readable by the
  app user — this adapter is not weaker than the production default, but it is also
  not a KMS. Do NOT use it on shared/multi-tenant hosts, and keep the file on an
  encrypted volume + backed up (losing it loses every tenant's audit key). For
  hardened deployments, back this behaviour with a real KMS/HSM adapter instead.

  ## Concurrency

  `set/2` and `delete/1` are read-modify-write over the whole file. A lost update here
  is NOT cosmetic: the losing tenant is already COMMITTED with its public audit key,
  so silently dropping its private key from disk permanently breaks that tenant's
  audit-chain signing/verification (a custody invariant). Both mutating paths are
  therefore serialized through a cluster-/node-wide lock (`:global.trans/2` keyed on
  the file path) so two concurrent signups apply their writes one-after-another
  instead of last-rename-wins. `get/1` is not locked — the atomic rename means a read
  always sees a complete old-or-new file. A KMS/HSM adapter remains the path for
  hardened deployments.
  """

  @behaviour Loopctl.Secrets.Behaviour

  require Logger

  @impl true
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(name) when is_binary(name) do
    with {:ok, map} <- read_all(),
         {:ok, b64} <- fetch(map, name) do
      decode(b64, name)
    end
  end

  @impl true
  @spec set(String.t(), binary()) :: :ok | {:error, term()}
  def set(name, value) when is_binary(name) and is_binary(value) do
    with_write_lock(fn ->
      with {:ok, map} <- read_all() do
        map
        |> Map.put(name, Base.encode64(value))
        |> write_all()
      end
    end)
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    with_write_lock(fn ->
      with {:ok, map} <- read_all() do
        map
        |> Map.delete(name)
        |> write_all()
      end
    end)
  end

  # --- internals ---

  # Serialize the read-modify-write so two concurrent signups cannot both read the
  # pre-write map and last-rename-wins-drop one tenant's audit key. `:global.trans/2`
  # defaults to infinite retries, so it blocks until the lock is acquired and then
  # returns the function's own result. The lock id is keyed on the target path so
  # distinct files (should there ever be more than one) don't contend.
  defp with_write_lock(fun) do
    :global.trans({{__MODULE__, path()}, self()}, fun)
  end

  defp fetch(map, name) do
    case Map.fetch(map, name) do
      {:ok, b64} -> {:ok, b64}
      :error -> {:error, :not_found}
    end
  end

  # A hand-corrupted secrets.json may hold a non-string value (number/array/object)
  # under a secret name — `decode_json/2` only validates the TOP level is a map. Guard
  # on `is_binary/1` so such a value returns `{:error, :corrupt_secret}` (like invalid
  # base64) instead of crashing `Base.decode64/1` with a FunctionClauseError on the
  # audit-key read path.
  defp decode(b64, name) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Logger.error("Secrets.LocalFileAdapter: secret #{inspect(name)} is not valid base64")
        {:error, :corrupt_secret}
    end
  end

  defp decode(_b64, name) do
    Logger.error("Secrets.LocalFileAdapter: secret #{inspect(name)} is not a string value")
    {:error, :corrupt_secret}
  end

  # A MISSING file is an empty store, not an error — first write creates it.
  defp read_all do
    path = path()

    case File.read(path) do
      {:ok, ""} -> {:ok, %{}}
      {:ok, contents} -> decode_json(contents, path)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:secrets_file_unreadable, reason}}
    end
  end

  defp decode_json(contents, path) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        Logger.error("Secrets.LocalFileAdapter: #{path} is not a JSON object; refusing to use it")
        {:error, :corrupt_secrets_file}
    end
  end

  defp write_all(map) do
    path = path()
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    # Bound the temp-file leak: a hard crash (power loss / SIGKILL) between
    # `File.touch/1` and `File.rename/2` leaves a `.tmp.N` sibling that the
    # same-invocation error path never reaches. This runs under `with_write_lock/1`,
    # so no other write is in flight and every existing sibling temp is a genuine
    # orphan — best-effort remove them before creating our own.
    sweep_stale_temps(path)

    with :ok <- ensure_dir(path),
         :ok <- write_private_tmp(tmp, Jason.encode!(map)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.error("Secrets.LocalFileAdapter: write to #{path} failed: #{inspect(reason)}")
        {:error, {:secrets_file_write_failed, reason}}
    end
  end

  # Best-effort cleanup of orphaned `<path>.tmp.<n>` siblings left by a hard crash
  # mid-write. Safe under the write lock (no concurrent write owns a temp file). Any
  # failure to list/remove is ignored — this only bounds an accumulation, it is never
  # on the correctness path.
  defp sweep_stale_temps(path) do
    dir = Path.dirname(path)
    prefix = Path.basename(path) <> ".tmp."

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.each(fn name -> _ = File.rm(Path.join(dir, name)) end)

      {:error, _reason} ->
        :ok
    end
  end

  # Create the temp file and lock it down to 0600 BEFORE writing any secret bytes, so
  # the plaintext-adjacent base64 is never present in a group/other-readable file (the
  # old order — File.write then chmod — left a readable window). Then fsync the bytes
  # to stable storage before the caller renames it into place.
  defp write_private_tmp(tmp, content) do
    with :ok <- File.touch(tmp),
         :ok <- File.chmod(tmp, 0o600),
         {:ok, io} <- File.open(tmp, [:write, :binary, :raw]) do
      try do
        with :ok <- IO.binwrite(io, content) do
          :file.sync(io)
        end
      after
        File.close(io)
      end
    end
  end

  defp ensure_dir(path) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir) do
      # Owner-only on the secrets directory so a newly created temp file can never be
      # listed/traversed by other local users even for the instant before its own
      # 0600 is applied. Best-effort on a pre-existing operator-owned dir.
      _ = File.chmod(dir, 0o700)
      :ok
    end
  end

  defp path do
    Application.get_env(:loopctl, :secrets_file) ||
      raise "Secrets.LocalFileAdapter is selected but :secrets_file (SECRETS_FILE) is not configured"
  end
end
