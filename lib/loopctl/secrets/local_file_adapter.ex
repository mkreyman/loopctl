defmodule Loopctl.Secrets.LocalFileAdapter do
  @moduledoc """
  selfhost fix: file-backed secrets adapter for non-Fly deployments.

  The only production adapter is Fly.io (`FlyAdapter`), which hard-fails off
  Fly (`:fly_not_configured`) and takes tenant signup down with it. This
  adapter keeps the same contract with a JSON file (values base64-encoded)
  at `SECRETS_FILE` (default `/data/secrets.json`), chmod 0600, atomic
  tmp+rename writes. Select via `SECRETS_ADAPTER=local_file` (runtime.exs).

  Threat model note: suitable for single-machine self-hosting where the host
  disk is trusted (FileVault + encrypted off-site backups). Not for shared
  infrastructure — that's what the Fly adapter is for.
  """

  @behaviour Loopctl.Secrets.Behaviour

  defp path, do: System.get_env("SECRETS_FILE") || "/data/secrets.json"

  defp read_all do
    with {:ok, bin} <- File.read(path()),
         {:ok, %{} = map} <- Jason.decode(bin) do
      map
    else
      _ -> %{}
    end
  end

  defp write_all(map) do
    p = path()
    File.mkdir_p!(Path.dirname(p))
    tmp = p <> ".tmp"
    File.write!(tmp, Jason.encode!(map))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, p)
    :ok
  rescue
    e -> {:error, {:local_secrets_write_failed, Exception.message(e)}}
  end

  @impl true
  def get(name) when is_binary(name) do
    case Map.fetch(read_all(), name) do
      {:ok, encoded} ->
        case Base.decode64(encoded) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :corrupt_secret}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def set(name, value) when is_binary(name) and is_binary(value) do
    read_all() |> Map.put(name, Base.encode64(value)) |> write_all()
  end

  @impl true
  def delete(name) when is_binary(name) do
    read_all() |> Map.delete(name) |> write_all()
  end
end
