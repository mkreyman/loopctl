defmodule Loopctl.Knowledge.StreamingExport.TarGz do
  @moduledoc """
  Forward-only, bounded-memory `.tar.gz` writer for the streaming export
  (US-27.16, AC-27.16.1/.3/.4).

  Wraps OTP's `:erl_tar` (stdlib — no new dependency) with a custom arity-2 writer
  fun and pipes every tar byte through a `:zlib` gzip deflate stream. Both
  `:erl_tar` and the deflate stream are STREAMING and forward-only, so peak memory
  holds at most the single entry currently being added plus a small deflate window
  — never the whole archive (which `:zip.create(_, [:memory])` materialized, the
  very thing the 5,000-article cap was guarding).

  ## Usage

      {:ok, w} = TarGz.init(fn iodata -> {:ok, Plug.Conn.chunk(conn, iodata)} end, conn)
      {:ok, w} = TarGz.add_entry(w, "pattern/x.md", content)
      {:ok, w} = TarGz.add_entry(w, "index.md", index)
      {:ok, conn} = TarGz.finish(w)   # writes the end-of-archive marker + gzip trailer
      # ... OR, on a mid-stream error, call abort/1 instead of finish/1 (see below).

  The `emit` fun is invoked with gzip-compressed iodata as each entry (and the
  trailer) is produced; the caller flushes it to the wire. `emit` returns
  `{:ok, conn}` (the conn threaded back so the caller keeps the updated `Plug.Conn`)
  or `{:error, reason}` to abort.

  ## FAIL-CLOSED contract (AC-27.16.4)

  A valid `.tar.gz` ends with the tar end-of-archive marker (two 512-byte zero
  blocks) followed by the gzip trailer (CRC32 + ISIZE). `finish/1` is the ONLY
  thing that writes them. So when the producer hits a mid-stream error (a Repo
  timeout, a dropped connection), the caller calls `abort/1` INSTEAD of `finish/1`:
  no end-of-archive is emitted and the gzip stream is never properly closed, so any
  conforming reader detects the truncation. Verified: `:erl_tar.extract` of the
  bytes produced WITHOUT `finish/1` returns `{:error, :eof}`. A partial bundle can
  therefore never be mistaken for a complete one by a restore pipeline.
  """

  alias __MODULE__

  @enforce_keys [:tar, :z, :emit, :conn, :state]
  defstruct [:tar, :z, :emit, :conn, :state]

  @typedoc "The flusher: receives compressed iodata, returns the threaded conn or an error."
  @type emit_fun :: (iodata() -> {:ok, term()} | {:error, term()})

  @opaque t :: %TarGz{
            tar: term(),
            z: :zlib.zstream(),
            emit: emit_fun(),
            conn: term(),
            state: :ets.tid()
          }

  @doc """
  Initializes a streaming `.tar.gz` writer.

  `emit` is called with compressed iodata to flush to the wire and must return
  `{:ok, conn}` (the threaded `Plug.Conn`, or any caller state) or
  `{:error, reason}`. `conn` is the initial threaded value.

  Returns `{:ok, writer}` or `{:error, reason}` if the initial gzip header couldn't
  be flushed.
  """
  @spec init(emit_fun(), term()) :: {:ok, t()} | {:error, term()}
  def init(emit, conn \\ nil) when is_function(emit, 1) do
    z = :zlib.open()
    # 31 = 15 (max window) + 16 (gzip wrapper). Default mem level / strategy.
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

    # Per-writer mutable scratch: {:buf, reversed_iolist} and {:pos, offset}. A
    # private ETS table (not the process dictionary) keeps the writer self-contained
    # and avoids any cross-writer key collision.
    state = :ets.new(__MODULE__.State, [:set, :private])
    :ets.insert(state, [{:buf, []}, {:pos, 0}])

    writer = %TarGz{tar: nil, z: z, emit: emit, conn: conn, state: state}
    fun = make_writer_fun(z, state)

    case :erl_tar.init(:streaming, :write, fun) do
      {:ok, tar} ->
        flush_buffer(%{writer | tar: tar})

      {:error, reason} ->
        cleanup(z, state)
        {:error, reason}
    end
  end

  @doc """
  Adds one file `path` with `content` to the archive, flushing the resulting
  compressed bytes via `emit`.

  Returns `{:ok, writer}` (conn threaded), or `{:error, reason}` if the tar add or
  the flush failed — in which case the caller must call `abort/1`, never `finish/1`.
  """
  @spec add_entry(t(), String.t(), iodata()) :: {:ok, t()} | {:error, term()}
  def add_entry(%TarGz{tar: tar} = w, path, content) when is_binary(path) do
    bin = IO.iodata_to_binary(content)

    case :erl_tar.add(tar, bin, String.to_charlist(path), []) do
      :ok -> flush_buffer(w)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Finalizes the archive: writes the tar end-of-archive marker, finishes the gzip
  stream, and flushes the trailing bytes. ONLY call this on the SUCCESS path — a
  finished archive signals completeness (AC-27.16.4).

  Returns `{:ok, conn}` or `{:error, reason}`. Frees the zlib + ETS resources.
  """
  @spec finish(t()) :: {:ok, term()} | {:error, term()}
  def finish(%TarGz{tar: tar, z: z, state: state} = w) do
    # :erl_tar.close writes the two zero blocks (end-of-archive) THROUGH our writer
    # fun, which deflates them into the buffer.
    with :ok <- close_tar(tar),
         {:ok, w} <- flush_buffer(w) do
      # Finish the gzip stream: final deflate block + gzip CRC/ISIZE trailer.
      trailer = :zlib.deflate(z, <<>>, :finish)
      safe_zlib_end(z)
      safe_zlib_close(z)
      result = emit(w, trailer)
      :ets.delete(state)
      result
    end
  end

  @doc """
  Abandons the writer WITHOUT finalizing (the fail-closed path): frees the zlib
  stream resource without emitting an end-of-archive marker or gzip trailer, so the
  bytes already sent form a detectably-incomplete archive. Emits nothing. Always
  returns `:ok`.
  """
  @spec abort(t()) :: :ok
  def abort(%TarGz{z: z, state: state}) do
    cleanup(z, state)
    :ok
  end

  # --- internals ---

  # Build the arity-2 :erl_tar writer fun (OTP 27 contract):
  #   Fun(write, {Handle, Data})  -> :ok | {:error, _}
  #   Fun(position, {Handle, Pos}) -> {:ok, AbsPos}  (Pos is {:cur, N} or absolute)
  #   Fun(close, Handle)          -> :ok
  # We are forward-only (gzip + chunked), so we track a running byte offset to
  # answer position queries and reject any backward seek (a sequential `add` never
  # seeks backward, so the reject is a guard, not a path).
  defp make_writer_fun(z, state) do
    fn
      :write, {_handle, data} ->
        bin = IO.iodata_to_binary(data)
        compressed = :zlib.deflate(z, bin)
        prepend_buf(state, compressed)
        advance_pos(state, byte_size(bin))
        :ok

      :position, {_handle, {:cur, n}} ->
        {:ok, current_pos(state) + n}

      :position, {_handle, pos} when is_integer(pos) ->
        if pos == current_pos(state),
          do: {:ok, pos},
          else: {:error, :non_sequential_tar_write}

      :close, _handle ->
        :ok
    end
  end

  # Pull the deflate-buffered compressed bytes and hand them to `emit`.
  defp flush_buffer(%TarGz{state: state} = w) do
    rev = :ets.lookup_element(state, :buf, 2)
    :ets.insert(state, {:buf, []})

    case rev do
      [] -> {:ok, w}
      iolist -> emit_threaded(w, :lists.reverse(iolist))
    end
  end

  defp emit_threaded(%TarGz{} = w, iodata) do
    case emit(w, iodata) do
      {:ok, conn} -> {:ok, %{w | conn: conn}}
      {:error, _} = err -> err
    end
  end

  defp emit(%TarGz{emit: emit, conn: conn}, iodata) do
    case emit.(iodata) do
      {:ok, new_conn} -> {:ok, new_conn}
      :ok -> {:ok, conn}
      {:error, _} = err -> err
    end
  end

  defp prepend_buf(state, compressed) do
    current = :ets.lookup_element(state, :buf, 2)
    :ets.insert(state, {:buf, [compressed | current]})
  end

  defp advance_pos(state, n) do
    :ets.update_counter(state, :pos, {2, n})
  end

  defp current_pos(state), do: :ets.lookup_element(state, :pos, 2)

  defp close_tar(tar) do
    :erl_tar.close(tar)
  rescue
    e -> {:error, e}
  end

  defp cleanup(z, state) do
    safe_zlib_end(z)
    safe_zlib_close(z)

    if :ets.info(state) != :undefined, do: :ets.delete(state)
    :ok
  end

  defp safe_zlib_end(z) do
    :zlib.deflateEnd(z)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_zlib_close(z) do
    :zlib.close(z)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
