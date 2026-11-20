defmodule LoopctlRunner.TraceShipTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{ByteRule, Contract, TraceShip}
  import LoopctlRunner.TestSupport

  @run_id "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f"
  @dispatch_id "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  @start %{acked: -1, offset: nil}
  @nul <<0>>

  defp run(root, lines, opts \\ []) do
    run_dir = Path.join(root, "run")
    File.mkdir_p!(run_dir)

    body = Enum.map_join(lines, &(line(&1) <> "\n"))
    File.write!(Path.join(run_dir, "trace.ndjson"), body <> Keyword.get(opts, :partial, ""))

    %{
      run_dir: run_dir,
      run_id: @run_id,
      dispatch_id: @dispatch_id,
      claim_epoch: 2,
      finished?: true
    }
  end

  defp line(raw) when is_binary(raw), do: raw
  defp line(event), do: JSON.encode!(event)

  defp event(seq, data \\ %{}) do
    %{
      "run_id" => @run_id,
      "seq" => seq,
      "event_id" => Integer.to_string(seq),
      "parent" => if(seq == 0, do: nil, else: "0"),
      "ts" => "2026-09-13T05:00:00Z",
      "type" => "claude.tool_use",
      "data" => data
    }
  end

  defp seqs({:ok, payload, _next}), do: Enum.map(payload["events"], & &1["seq"])

  describe "ByteRule, as loopctl counts" do
    test "strings, keys, scalars and containers" do
      assert ByteRule.bytes("ab") == 6 * 2 + 12
      assert ByteRule.bytes("") == 12
      # A character outside the BMP is two UTF-16 units.
      assert ByteRule.bytes(<<0x1F600::utf8>>) == 6 * 2 + 12
      assert ByteRule.bytes(<<0xE9::utf8>>) == 6 + 12
      assert ByteRule.bytes(1) == 32
      assert ByteRule.bytes(1.5) == 32
      assert ByteRule.bytes(nil) == 32
      assert ByteRule.bytes(true) == 32
      assert ByteRule.bytes([]) == 2
      assert ByteRule.bytes([nil]) == 2 + 2 + 32
      # A key is charged as a string, the per-string 12 included.
      assert ByteRule.bytes(%{"a" => 1}) == 2 + 2 + (6 + 12) + 32
    end
  end

  describe "batches" do
    test "hold at most the contract's event count, in seq order, after the acknowledgement" do
      r = run(tmp_dir!("ship-count"), Enum.map(0..44, &event/1))

      assert {:ok, payload, %{acked: 19, offset: offset}} = TraceShip.next_batch(r, @start)
      assert Enum.map(payload["events"], & &1["seq"]) == Enum.to_list(0..19)
      assert Contract.validate("RunnerTraceBatch", payload) == :ok
      assert %{"run_id" => @run_id, "dispatch_id" => @dispatch_id, "claim_epoch" => 2} = payload
      assert is_integer(offset)

      assert seqs(TraceShip.next_batch(r, %{acked: 39, offset: nil})) == Enum.to_list(40..44)
      # Caught up: the position comes back with the offset filled in, so an idle run is read
      # from the end of its file next time, not from the start.
      size = File.stat!(Path.join(r.run_dir, "trace.ndjson")).size

      assert TraceShip.next_batch(r, %{acked: 44, offset: nil}) ==
               {:none, %{acked: 44, offset: size}}
    end

    test "resume from the byte offset the last batch ended at" do
      r = run(tmp_dir!("ship-offset"), Enum.map(0..44, &event/1))

      {:ok, _, next} = TraceShip.next_batch(r, @start)
      assert seqs(TraceShip.next_batch(r, next)) == Enum.to_list(20..39)

      # An offset that no longer points at the next seq is not trusted: the batch is read from
      # the start, so its events are the real ones, not stubs of whatever the offset hit.
      assert {:ok, payload, _} = TraceShip.next_batch(r, %{acked: 19, offset: 3})
      assert Enum.map(payload["events"], & &1["seq"]) == Enum.to_list(20..39)

      assert Enum.all?(
               payload["events"],
               &(&1["type"] == "claude.tool_use" and &1["data"] == %{})
             )
    end

    test "stay under the byte budget, split where the next event would exceed it" do
      # About 5,100 bytes of data each: under the 6,000 event cap, twenty far over 60,000.
      data = %{"text" => String.duplicate("x", 845)}
      r = run(tmp_dir!("ship-bytes"), Enum.map(0..19, &event(&1, data)))

      assert {:ok, payload, %{acked: last}} = TraceShip.next_batch(r, @start)
      assert ByteRule.bytes(payload) <= 60_000
      assert last < 19
      grown = Map.update!(payload, "events", &(&1 ++ [event(last + 1, data)]))
      assert ByteRule.bytes(grown) > 60_000
    end

    test "an event too large to ship is sent with its data replaced by a size marker" do
      big = %{"text" => String.duplicate("y", 2_000)}
      r = run(tmp_dir!("ship-large"), [event(0), event(1, big), event(2)])

      assert {:ok, payload, _} = TraceShip.next_batch(r, @start)
      [_, shipped, _] = payload["events"]
      assert %{"omitted" => "data_too_large", "data_bytes" => bytes} = shipped["data"]
      assert bytes > 6_000
      assert ByteRule.bytes(shipped) <= 12_000
      # The file keeps the full event.
      assert File.read!(Path.join(r.run_dir, "trace.ndjson")) =~ String.duplicate("y", 2_000)
    end

    test "a batch that still fails the contract is returned as an error, never sent" do
      r = run(tmp_dir!("ship-invalid"), [event(0)])
      assert {:error, [_ | _]} = TraceShip.next_batch(%{r | dispatch_id: "d-1"}, @start)
    end

    test "named seqs ship without their data, or as stubs" do
      events = [event(0, %{"a" => 1}), event(1, %{"b" => 2}), event(2, %{"c" => 3})]
      r = run(tmp_dir!("ship-omit"), events)

      assert {:ok, payload, _} = TraceShip.next_batch(r, @start, omit_seqs: [1], stub_seqs: [2])

      assert [
               %{"data" => %{"a" => 1}},
               %{"data" => %{"omitted" => "data_too_large"}},
               %{"seq" => 2, "data" => %{"omitted" => "invalid_payload"}} = stub
             ] = payload["events"]

      # Nothing of the refused event survives into its stub: any field may be what was refused.
      assert %{"type" => "trace.unshippable", "parent" => "0", "event_id" => "2"} = stub
      refute stub["ts"] == "2026-09-13T05:00:00Z"
    end
  end

  describe "every shipped event is one loopctl accepts" do
    test "lengths, NULs, wide integers, a bad ts, non-object data and unknown keys" do
      bad =
        Map.merge(event(0), %{
          "event_id" => String.duplicate("e", 200),
          "type" => "claude." <> String.duplicate("t", 100),
          "ts" => "yesterday",
          "extra" => "dropped",
          "run_id" => "someone-elses"
        })

      odd = Map.merge(event(1), %{"parent" => 0, "data" => "just a string"})
      wide = Integer.pow(10, 40)
      nul = event(2, %{"error" => "bad" <> @nul <> "byte", "big" => wide, ("k" <> @nul) => 1})

      r = run(tmp_dir!("ship-clean"), [bad, odd, nul])
      assert {:ok, payload, _} = TraceShip.next_batch(r, @start)
      assert Contract.validate("RunnerTraceBatch", payload) == :ok

      [first, second, third] = payload["events"]
      assert first["run_id"] == @run_id
      assert String.length(first["event_id"]) == 128
      assert String.length(first["type"]) == 64
      assert {:ok, _, _} = DateTime.from_iso8601(first["ts"])
      refute Map.has_key?(first, "extra")
      assert second["parent"] == "0"
      assert second["data"] == %{"value" => "just a string"}

      assert third["data"] == %{
               "error" => "badbyte",
               "big" => Integer.to_string(wide),
               "k" => 1
             }
    end

    test "a non-root event whose parent is missing or empty hangs under the root" do
      r =
        run(tmp_dir!("ship-parent"), [
          event(0),
          Map.put(event(1), "parent", ""),
          Map.delete(event(2), "parent")
        ])

      assert {:ok, %{"events" => [root, one, two]}, _} = TraceShip.next_batch(r, @start)
      assert root["parent"] == nil
      assert one["parent"] == "0"
      assert two["parent"] == "0"
    end

    test "a line that does not decode, or names another seq, ships as a stub under its seq" do
      r = run(tmp_dir!("ship-stub"), [event(0), "{not json", event(7)])

      assert {:ok, payload, _} = TraceShip.next_batch(r, @start)
      assert [%{"seq" => 0}, one, two] = payload["events"]
      assert %{"seq" => 1, "parent" => "0", "data" => %{"omitted" => "unreadable_line"}} = one
      assert %{"seq" => 2, "data" => %{"omitted" => "unreadable_line"}} = two
      assert Contract.validate("RunnerTraceBatch", payload) == :ok
    end
  end

  describe "reading the trace" do
    test "a line still being written is not read until it is complete" do
      partial = ~s({"run_id":"#{@run_id}","seq":2,"eve)
      r = run(tmp_dir!("ship-partial"), [event(0), event(1)], partial: partial)

      assert seqs(TraceShip.next_batch(r, @start)) == [0, 1]
      assert {_bytes, 1} = TraceShip.last_seq(r)
    end

    test "resuming after a cursor skips acknowledged lines across read chunks, blank lines too" do
      # Small enough that twenty fit a batch, large enough that seq 250 is past the first chunk.
      data = %{"text" => String.duplicate("w", 200)}
      lines = Enum.map(0..299, &event(&1, data))
      # A blank line is not a seq, here or in read_lines.
      lines = List.insert_at(lines, 120, "")
      r = run(tmp_dir!("ship-skip"), lines)

      assert {:ok, payload, %{offset: offset}} =
               TraceShip.next_batch(r, %{acked: 250, offset: nil})

      assert Enum.map(payload["events"], & &1["seq"]) == Enum.to_list(251..270)
      assert Enum.all?(payload["events"], &(&1["type"] == "claude.tool_use"))
      assert offset > 65_536
    end

    test "the last seq comes from the tail of a trace larger than one read" do
      data = %{"text" => String.duplicate("z", 500)}
      r = run(tmp_dir!("ship-tail"), Enum.map(0..299, &event(&1, data)), partial: ~s({"seq":300}))

      assert {bytes, 299} = TraceShip.last_seq(r)
      assert bytes > 65_536
      assert bytes == File.stat!(Path.join(r.run_dir, "trace.ndjson")).size
    end
  end

  describe "which runs ship" do
    defp state_run(runs_dir, name, state) do
      run_dir = Path.join(runs_dir, name)
      File.mkdir_p!(run_dir)
      LoopctlRunner.RunState.update(run_dir, Map.put_new(state, "status", "succeeded"))
      run_dir
    end

    defp names(runs_dir),
      do: runs_dir |> TraceShip.runs() |> Enum.map(&Path.basename(&1.run_dir)) |> Enum.sort()

    test "only a run bound to a dispatch by UUIDs and an epoch, and not settled unchanged" do
      runs_dir = Path.join(tmp_dir!("ship-which"), "runs")
      bound = %{"run_id" => @run_id, "dispatch_id" => @dispatch_id, "claim_epoch" => 0}

      state_run(runs_dir, "bound", bound)
      state_run(runs_dir, "hand-filed", Map.drop(bound, ["dispatch_id", "claim_epoch"]))
      state_run(runs_dir, "legacy-id", %{bound | "run_id" => "story-1-20260912"})
      state_run(runs_dir, "bad-dispatch", %{bound | "dispatch_id" => "d-1"})
      state_run(runs_dir, "negative-epoch", %{bound | "claim_epoch" => -1})
      abandoned = state_run(runs_dir, "abandoned", bound)
      :ok = TraceShip.mark_abandoned(%{run_dir: abandoned}, "stale_claim_epoch")

      done = state_run(runs_dir, "done", bound)
      trace = Path.join(done, "trace.ndjson")
      File.write!(trace, line(event(0)) <> "\n")
      :ok = TraceShip.mark_done(%{run_dir: done}, 0, File.stat!(trace).size)

      assert names(runs_dir) == ["bound"]

      # The reaper appends to a finished run's trace: a done run that grew ships again.
      File.write!(trace, line(event(1)) <> "\n", [:append])
      assert names(runs_dir) == ["bound", "done"]
    end

    test "recording a settle that cannot be written returns an error instead of raising" do
      missing = %{run_dir: Path.join(tmp_dir!("ship-missing"), "gone")}
      assert {:error, _} = TraceShip.mark_done(missing, 3, 100)
      assert {:error, _} = TraceShip.mark_abandoned(missing, "run_mismatch")
    end
  end
end
