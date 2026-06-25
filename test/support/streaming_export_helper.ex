defmodule Loopctl.StreamingExportHelper do
  @moduledoc """
  Test helper for the US-27.16 streaming export.

  `to_targz_binary/3` drives `Loopctl.Knowledge.StreamingExport.stream/4` with an
  in-memory collector `emit` fun (no HTTP) and returns the FULL `.tar.gz` binary —
  used by the OKF round-trip and small-corpus tests that assert on archive
  contents. `extract/1` unpacks a `.tar.gz` binary into a `%{path => content}` map.

  NOTE: This collects ALL chunks into memory and is for SMALL corpora only. The
  bounded-memory / real-chunked-transport assertions (TC-27.16.1/.3) must NOT use
  this — they drive the real chunked HTTP transport (see the scale test).
  """

  alias Loopctl.Knowledge.StreamingExport

  @doc """
  Streams the export for `tenant_id`/`format` and returns `{:ok, targz_binary}` or
  `{:error, reason}`. `opts` is forwarded to `StreamingExport.stream/4`.
  """
  @spec to_targz_binary(Ecto.UUID.t(), module(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def to_targz_binary(tenant_id, format, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    emit = fn iodata ->
      Agent.update(agent, fn acc -> [IO.iodata_to_binary(iodata) | acc] end)
      {:ok, :collected}
    end

    result = StreamingExport.stream(tenant_id, format, emit, Keyword.put(opts, :conn, :collected))
    bytes = Agent.get(agent, fn acc -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)
    Agent.stop(agent)

    case result do
      {:ok, _conn} -> {:ok, bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extracts a `.tar.gz` binary into a `%{path => content}` map. Returns
  `{:ok, map}` or `{:error, reason}` (a truncated/invalid archive errors — the
  fail-closed signal).
  """
  @spec extract(binary()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def extract(targz) when is_binary(targz) do
    case :erl_tar.extract({:binary, targz}, [:memory, :compressed]) do
      {:ok, entries} ->
        {:ok, Map.new(entries, fn {name, content} -> {to_string(name), content} end)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
