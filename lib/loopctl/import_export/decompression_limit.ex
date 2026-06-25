defmodule Loopctl.ImportExport.DecompressionLimit do
  @moduledoc """
  Decompression-bomb defense for archive imports (US-27.16, AC-27.16.3, #3).

  Two layers bound a malicious archive (a tiny compressed file that inflates to
  gigabytes) BEFORE it can OOM the node:

    1. A COMPRESSED-input cap (`:import_export_max_compressed_bytes`, default 50 MB):
       rejected before any inflation. Cheap, bounds the attacker's input.
    2. A streaming inflate with a running UNCOMPRESSED byte budget
       (`:import_export_max_decompressed_bytes`, default 200 MB): aborts
       MID-decompression the instant the budget is exceeded — never materializing
       the full bomb. This is what `:erl_tar.extract([:memory, :compressed])` and
       `:zip.extract([:memory])` do NOT do (they fully inflate first).

  `extract_tar_gz/1` covers the gzip path; `guard_compressed_size/1` is the cheap
  pre-check the zip path uses (zip has no simple streaming-inflate API, so it relies
  on the compressed-input cap plus the per-entry total-size cap in the caller).
  """

  @default_max_decompressed_bytes 200 * 1024 * 1024
  @default_max_compressed_bytes 50 * 1024 * 1024

  @doc """
  Rejects an archive whose COMPRESSED size already exceeds the input cap, before any
  decompression. Returns `:ok` or `{:error, :payload_too_large}`.
  """
  @spec guard_compressed_size(binary()) :: :ok | {:error, :payload_too_large}
  def guard_compressed_size(bin) when is_binary(bin) do
    if byte_size(bin) > max_compressed_bytes(),
      do: {:error, :payload_too_large},
      else: :ok
  end

  @doc """
  Extracts a gzip-compressed tar archive with BOTH a compressed-input cap and a
  streaming decompressed-byte budget.

  Returns `{:ok, entries}` (same shape as `:erl_tar.extract/2`) or
  `{:error, :payload_too_large}` if either cap would be exceeded, or
  `{:error, reason}` for other tar/gzip errors.
  """
  @spec extract_tar_gz(binary()) :: {:ok, list()} | {:error, atom()}
  def extract_tar_gz(bin) when is_binary(bin) do
    with :ok <- guard_compressed_size(bin) do
      do_extract_tar_gz(bin, max_decompressed_bytes())
    end
  end

  defp do_extract_tar_gz(bin, max_bytes) do
    z = :zlib.open()

    try do
      # 16 + 15 = gzip wrapper + max window bits.
      :zlib.inflateInit(z, 16 + 15)

      case decompress_streaming(z, bin, [], 0, max_bytes) do
        {:ok, decompressed} ->
          case :erl_tar.extract({:binary, decompressed}, [:memory]) do
            {:ok, entries} -> {:ok, entries}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      _ -> {:error, :invalid_archive}
    catch
      _, _ -> {:error, :invalid_archive}
    after
      safe_zlib_close(z)
    end
  end

  # Feed the compressed input to zlib in 64KB slices, accumulating the inflated
  # output (an IOLIST — `:zlib.inflate/2` returns a LIST of binaries, NOT a single
  # binary) and aborting the instant the running uncompressed total exceeds the
  # budget. Returns `{:ok, decompressed_binary}` or `{:error, :payload_too_large}`.
  defp decompress_streaming(z, input, acc, total, max) do
    cond do
      total > max ->
        {:error, :payload_too_large}

      input == <<>> ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

      true ->
        chunk_size = min(65_536, byte_size(input))
        <<chunk::binary-size(chunk_size), rest::binary>> = input

        produced = :zlib.inflate(z, chunk)
        new_total = total + IO.iodata_length(produced)

        if new_total > max do
          {:error, :payload_too_large}
        else
          decompress_streaming(z, rest, [produced | acc], new_total, max)
        end
    end
  rescue
    _ -> {:error, :invalid_archive}
  end

  defp safe_zlib_close(z) do
    :zlib.close(z)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Configured max DECOMPRESSED size (bytes)."
  @spec max_decompressed_bytes() :: pos_integer()
  def max_decompressed_bytes do
    Application.get_env(
      :loopctl,
      :import_export_max_decompressed_bytes,
      @default_max_decompressed_bytes
    )
  end

  @doc "Configured max COMPRESSED input size (bytes)."
  @spec max_compressed_bytes() :: pos_integer()
  def max_compressed_bytes do
    Application.get_env(
      :loopctl,
      :import_export_max_compressed_bytes,
      @default_max_compressed_bytes
    )
  end
end
