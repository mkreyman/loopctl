defmodule Loopctl.Secrets.LocalFileAdapter do
  @moduledoc """
  File-backed `Loopctl.Secrets.Behaviour` for SELF-HOSTED, single-machine installs
  that are not on Fly (#496). Select it in `config/runtime.exs` with
  `SECRETS_ADAPTER=local_file`; the file path defaults to `SECRETS_FILE` (see
  `runtime.exs`).

  Secrets (currently only the per-tenant audit signing private keys) are stored as a
  single JSON object `{name => base64(value)}` on disk. Writes are ATOMIC — a sibling
  temp file is written then `rename/2`d over the target (a same-directory rename is
  atomic on POSIX) — and the file is created `0600` (owner read/write only), so a
  crash mid-write never leaves a torn file and other local users cannot read it.

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

  `set/2` and `delete/1` are read-modify-write. Two writes to DIFFERENT names racing
  can lose one update (last atomic rename wins). Acceptable for the single-operator
  model — the only writer today is tenant signup, which is rare and operator-driven —
  and documented rather than papered over. A KMS adapter or a serializing GenServer
  is the path if concurrent secret writes ever become common.
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
    with {:ok, map} <- read_all() do
      map
      |> Map.put(name, Base.encode64(value))
      |> write_all()
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    with {:ok, map} <- read_all() do
      map
      |> Map.delete(name)
      |> write_all()
    end
  end

  # --- internals ---

  defp fetch(map, name) do
    case Map.fetch(map, name) do
      {:ok, b64} -> {:ok, b64}
      :error -> {:error, :not_found}
    end
  end

  defp decode(b64, name) do
    case Base.decode64(b64) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Logger.error("Secrets.LocalFileAdapter: secret #{inspect(name)} is not valid base64")
        {:error, :corrupt_secret}
    end
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

    with :ok <- ensure_dir(path),
         :ok <- File.write(tmp, Jason.encode!(map)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.error("Secrets.LocalFileAdapter: write to #{path} failed: #{inspect(reason)}")
        {:error, {:secrets_file_write_failed, reason}}
    end
  end

  defp ensure_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp path do
    Application.get_env(:loopctl, :secrets_file) ||
      raise "Secrets.LocalFileAdapter is selected but :secrets_file (SECRETS_FILE) is not configured"
  end
end
