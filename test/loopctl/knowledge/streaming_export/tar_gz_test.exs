defmodule Loopctl.Knowledge.StreamingExport.TarGzTest do
  @moduledoc """
  US-27.16 (AC-27.16.1/.4): the streamed `.tar.gz` writer and its fail-closed
  contract. Pure in-memory (no DB / no HTTP), fully async.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.StreamingExport.TarGz

  defp collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    emit = fn iodata ->
      Agent.update(agent, fn acc -> [IO.iodata_to_binary(iodata) | acc] end)
      {:ok, :collected}
    end

    {agent, emit}
  end

  defp bytes(agent) do
    Agent.get(agent, fn acc -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)
  end

  test "a finished archive extracts to exactly the added entries" do
    {agent, emit} = collector()

    {:ok, w} = TarGz.init(emit, :collected)
    {:ok, w} = TarGz.add_entry(w, "a/one.md", "first body")
    {:ok, w} = TarGz.add_entry(w, "b/two.md", "second body")
    {:ok, :collected} = TarGz.finish(w)

    archive = bytes(agent)
    assert <<0x1F, 0x8B, _::binary>> = archive

    assert {:ok, entries} = :erl_tar.extract({:binary, archive}, [:memory, :compressed])
    map = Map.new(entries, fn {name, content} -> {to_string(name), content} end)
    assert map == %{"a/one.md" => "first body", "b/two.md" => "second body"}
  end

  test "FAIL-CLOSED: bytes produced WITHOUT finish/1 form a detectably-incomplete archive" do
    {agent, emit} = collector()

    {:ok, w} = TarGz.init(emit, :collected)
    {:ok, w} = TarGz.add_entry(w, "a/one.md", "first body")
    {:ok, _w} = TarGz.add_entry(w, "b/two.md", "second body")
    # Simulate a mid-stream abort: we DO NOT call finish/1, we abort.
    :ok = TarGz.abort(w)

    partial = bytes(agent)

    # Without the end-of-archive marker + gzip trailer, a conforming reader MUST
    # detect the truncation — no `{:ok, ...}`.
    assert {:error, _reason} = :erl_tar.extract({:binary, partial}, [:memory, :compressed])
  end

  test "abort/1 frees resources and emits nothing further" do
    {agent, emit} = collector()
    {:ok, w} = TarGz.init(emit, :collected)
    {:ok, w} = TarGz.add_entry(w, "x.md", "x")
    before = byte_size(bytes(agent))
    :ok = TarGz.abort(w)
    # abort emits no additional bytes.
    assert byte_size(bytes(agent)) == before
  end

  test "an emit error mid-write is propagated (so the caller can fail closed)" do
    # An emit fun that fails on the SECOND flush simulates a dropped client socket.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    emit = fn _iodata ->
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      if n >= 2, do: {:error, :closed}, else: {:ok, :collected}
    end

    {:ok, w} = TarGz.init(emit, :collected)

    # Keep adding entries until an emit error surfaces.
    result =
      Enum.reduce_while(1..50, {:ok, w}, fn i, {:ok, w} ->
        case TarGz.add_entry(w, "f#{i}.md", String.duplicate("x", 1000)) do
          {:ok, w} -> {:cont, {:ok, w}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    assert {:error, :closed} = result
  end

  test "finish/1 frees the zlib + ETS resources even when the final flush errors (#9)" do
    # An emit fun that succeeds until finish/1's trailer flush, then errors —
    # simulating a client disconnect during finalization. finish/1 must still free
    # the zlib stream + the per-writer ETS table (no leak).
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    emit = fn _iodata ->
      # Fail only once we've emitted a couple of flushes (the header + entry), so the
      # failure lands at/around the finish trailer flush.
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      if n >= 3, do: {:error, :closed}, else: {:ok, :collected}
    end

    {:ok, w} = TarGz.init(emit, :collected)
    {:ok, w} = TarGz.add_entry(w, "a.md", "a")

    state_tid = w.state
    assert :ets.info(state_tid) != :undefined

    # finish errors mid-finalize; resources must STILL be freed.
    assert {:error, :closed} = TarGz.finish(w)
    assert :ets.info(state_tid) == :undefined
  end

  test "finish/1 frees the ETS table on the success path too" do
    {agent, emit} = collector()
    {:ok, w} = TarGz.init(emit, :collected)
    {:ok, w} = TarGz.add_entry(w, "a.md", "a")
    state_tid = w.state
    {:ok, :collected} = TarGz.finish(w)
    assert :ets.info(state_tid) == :undefined
    # Sanity: success path produced a valid archive.
    assert {:ok, _} = :erl_tar.extract({:binary, bytes(agent)}, [:memory, :compressed])
  end
end
