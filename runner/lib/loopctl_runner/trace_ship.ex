defmodule LoopctlRunner.TraceShip do
  @moduledoc """
  What the trace shipper sends next (design §11, runner contract 1.1 `trace` and
  `trace_cursor`). Decisions and file reads over the run directories; `LoopctlRunner.Control`
  owns the socket and performs them.

  The on-disk trace is the source of truth. For each run the shipper asks loopctl where its
  stored copy ends (`trace_cursor`, after every join, since a rejoin replays nothing), then
  ships the lines after `acked_seq` in batches, one push at a time, and advances on each
  `RunnerTraceAck`.

  ## Which runs ship

  loopctl stores a trace only for a dispatch this runner ACCEPTED, at its `claim_epoch`, so a
  run ships only when its `state.json` names `dispatch_id` and `claim_epoch` beside a UUID
  `run_id`. A hand-filed run carries neither and is never shipped; the dispatch accept path
  (build order step 6) is what writes them.

  A run is settled in its `trace_ship.json`: `done` once it has finished and loopctl holds its
  last complete line, recording the trace's size then, or `abandoned` when loopctl refuses its
  dispatch for a reason resending cannot change. A done run whose trace has since grown ships
  again: the reaper appends `run.reaped` to a finished run's trace when a later run starts.

  ## Every event shipped is one loopctl accepts

  A line is shipped as a contract `RunnerTraceEvent`: `run_id` is the run's, unknown keys are
  dropped, `event_id`, `parent` and `type` are cut to their lengths, a bad `ts` is replaced,
  and NULs and integers of 31 or more digits (which loopctl refuses as storable values) are
  made safe. A line that does not decode is shipped as a stub under its seq, so the
  acknowledgement can still pass it. An event whose `data` exceeds
  `trace_max_event_data_bytes`, or which exceeds `trace_max_event_bytes` whole, is shipped with
  `data` replaced by a marker naming its size. The batch is validated against the contract
  before it is returned. The file keeps every event as written.

  ## Reading cheaply

  A batch is at most `trace_max_events` events and `trace_max_batch_bytes` under
  `LoopctlRunner.ByteRule`. It is read from a byte offset, the end of the last line shipped,
  in chunks, only until enough complete lines are in hand; without an offset (after a cursor)
  the file is read from the start. Only complete lines are read, so a line still being written
  is left for the next pass.
  """

  alias LoopctlRunner.{ByteRule, Contract, Owner, RunState}

  @limits Map.fetch!(Contract.connection(), "limits")
  @max_events Map.fetch!(@limits, "trace_max_events")
  @max_batch_bytes Map.fetch!(@limits, "trace_max_batch_bytes")
  @max_event_bytes Map.fetch!(@limits, "trace_max_event_bytes")
  @max_data_bytes Map.fetch!(@limits, "trace_max_event_data_bytes")
  @max_digits get_in(@limits, ["json_byte_rule", "max_number_digits"])
  @in_flight ["starting", "running"]
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @chunk 65_536

  @type run :: %{
          run_dir: String.t(),
          run_id: String.t(),
          dispatch_id: String.t(),
          claim_epoch: non_neg_integer(),
          finished?: boolean()
        }

  @type position :: %{acked: integer(), offset: non_neg_integer() | nil}

  @doc "The min interval between `trace` pushes, and between `trace_cursor` pushes, in ms."
  @spec min_interval_ms(String.t()) :: pos_integer()
  def min_interval_ms(event), do: get_in(@limits, ["min_interval_ms", event])

  @doc "The contract's cap on events in one batch."
  @spec max_events() :: pos_integer()
  def max_events, do: @max_events

  @doc "Runs under `runs_dir` that ship: bound to a dispatch, not abandoned, not done unchanged."
  @spec runs(String.t()) :: [run()]
  def runs(runs_dir) do
    for {run_dir, state} <- RunState.all(runs_dir),
        run = shippable(run_dir, state),
        run != nil,
        unsettled?(run_dir),
        do: run
  end

  defp shippable(
         run_dir,
         %{"run_id" => run_id, "dispatch_id" => dispatch_id, "claim_epoch" => epoch} = state
       )
       when is_binary(run_id) and is_binary(dispatch_id) and is_integer(epoch) and epoch >= 0 do
    if Regex.match?(@uuid, run_id) and Regex.match?(@uuid, dispatch_id) do
      %{
        run_dir: run_dir,
        run_id: run_id,
        dispatch_id: dispatch_id,
        claim_epoch: epoch,
        finished?: not (state["status"] in @in_flight and Owner.alive?(state))
      }
    end
  end

  defp shippable(_run_dir, _state), do: nil

  defp unsettled?(run_dir) do
    case read_settled(run_dir) do
      nil ->
        true

      %{"abandoned" => _} ->
        false

      %{"done" => true, "trace_bytes" => bytes} when is_integer(bytes) ->
        trace_size(run_dir) > bytes

      _ ->
        false
    end
  end

  @doc """
  The next `RunnerTraceBatch` for `run` from `position`, as `{:ok, payload, next_position}`
  where `next_position` is where the batch's last line ends; `{:none, position}` when nothing
  complete is left, with the offset where the acknowledged lines end filled in so an idle run
  is not re-read from the start; or `{:error, errors}` if the prepared batch still fails the
  contract.

  `max_events` lowers the event cap, for a run the server refused as too large; `omit_seqs`
  names events to ship without their data, and `stub_seqs` events to ship as stubs, for ones
  the server refused whole.
  """
  @spec next_batch(run(), position(), keyword()) ::
          {:ok, map(), position()} | {:none, position()} | {:error, [String.t()]}
  def next_batch(run, %{acked: acked} = position, opts \\ []) do
    max_events = opts |> Keyword.get(:max_events, @max_events) |> min(@max_events) |> max(1)
    {lines, start} = lines_after(run, position, max_events)

    case lines do
      [] ->
        {:none, %{acked: acked, offset: start}}

      lines ->
        omit = Keyword.get(opts, :omit_seqs, [])
        stub = Keyword.get(opts, :stub_seqs, [])

        events =
          lines
          |> Enum.with_index(acked + 1)
          |> Enum.map(fn {{line, line_end}, expected} ->
            {prepare(line, expected, run, omit, stub), line_end}
          end)

        {payload, line_end} = fill(base(run), events, nil)
        last = payload["events"] |> List.last() |> Map.fetch!("seq")

        case Contract.validate("RunnerTraceBatch", payload) do
          :ok -> {:ok, payload, %{acked: last, offset: line_end}}
          {:error, errors} -> {:error, errors}
        end
    end
  end

  defp base(run) do
    %{
      "run_id" => run.run_id,
      "dispatch_id" => run.dispatch_id,
      "claim_epoch" => run.claim_epoch,
      "events" => []
    }
  end

  # Events in seq order until the batch would exceed its byte budget; always at least one,
  # which prepare/5 has already made fit a batch on its own.
  defp fill(payload, [{event, line_end} | rest], last_end) do
    grown = Map.update!(payload, "events", &(&1 ++ [event]))

    if payload["events"] == [] or ByteRule.bytes(grown) <= @max_batch_bytes,
      do: fill(grown, rest, line_end),
      else: {payload, last_end}
  end

  defp fill(payload, [], last_end), do: {payload, last_end}

  # Complete lines after `acked`, each with the byte offset where it ends, and the offset they
  # start at (nil if unknown). From the recorded offset when there is one and the line there
  # carries the next seq; otherwise from the start, skipping one line per acknowledged seq,
  # which holds because seqs are gapless from 0.
  defp lines_after(run, %{acked: acked, offset: offset}, max_events) do
    path = trace_path(run.run_dir)

    from_offset(path, offset, acked, max_events) ||
      from_start(path, acked, max_events)
  end

  # The lines from a recorded offset, or nil when there is none or it no longer points at the
  # next seq. No lines is a real answer: nothing new has been written.
  defp from_offset(_path, nil, _acked, _max_events), do: nil

  defp from_offset(path, offset, acked, max_events) do
    case read_lines(path, offset, max_events) do
      [] -> {[], offset}
      [{line, _} | _] = lines -> if seq_of(line) == acked + 1, do: {lines, offset}
    end
  end

  # Skipping the acknowledged lines keeps only a running offset, never the lines themselves: a
  # long trace must not be loaded whole to find where one line ends.
  defp from_start(path, acked, max_events) do
    case skip_lines(path, acked + 1) do
      {:ok, start} -> {read_lines(path, start, max_events), start}
      :short -> {[], nil}
    end
  end

  # The byte offset just past the `count`-th non-empty complete line, or :short.
  defp skip_lines(_path, 0), do: {:ok, 0}

  defp skip_lines(path, count) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          skip(io, 0, count, true)
        after
          File.close(io)
        end

      {:error, _} ->
        :short
    end
  end

  # `line_empty?` is whether the line being scanned has no bytes yet, so blank lines, which
  # read_lines/3 does not return, are not counted either.
  defp skip(io, pos, count, line_empty?) do
    case :file.pread(io, pos, @chunk) do
      {:ok, chunk} ->
        case count_newlines(chunk, 0, count, line_empty?) do
          {:done, at} -> {:ok, pos + at}
          {:more, left, empty?} -> skip(io, pos + byte_size(chunk), left, empty?)
        end

      _eof_or_error ->
        :short
    end
  end

  defp count_newlines(chunk, at, count, empty?) when at >= byte_size(chunk),
    do: {:more, count, empty?}

  defp count_newlines(chunk, at, count, empty?) do
    case :binary.match(chunk, "\n", scope: {at, byte_size(chunk) - at}) do
      :nomatch ->
        {:more, count, empty? and at == byte_size(chunk)}

      {nl, 1} ->
        blank = empty? and nl == at
        left = if blank, do: count, else: count - 1

        if left == 0,
          do: {:done, nl + 1},
          else: count_newlines(chunk, nl + 1, left, true)
    end
  end

  # Up to `count` complete lines from byte `offset`, read a chunk at a time.
  defp read_lines(path, offset, count) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          collect(io, offset, <<>>, offset, count, [])
        after
          File.close(io)
        end

      {:error, _} ->
        []
    end
  end

  defp collect(_io, _pos, _pending, _pending_start, 0, acc), do: Enum.reverse(acc)

  defp collect(io, pos, pending, pending_start, count, acc) do
    case :file.pread(io, pos, @chunk) do
      {:ok, chunk} ->
        {lines, rest, rest_start} = split_complete(pending <> chunk, pending_start)
        {taken, _} = Enum.split(lines, count)
        acc = Enum.reverse(taken, acc)
        left = count - length(taken)

        if left == 0 or byte_size(chunk) < @chunk,
          do: Enum.reverse(acc),
          else: collect(io, pos + byte_size(chunk), rest, rest_start, left, acc)

      _eof_or_error ->
        Enum.reverse(acc)
    end
  end

  # Complete lines with the offset each ends at (past its newline), and the trailing partial.
  defp split_complete(buffer, start) do
    parts = :binary.split(buffer, "\n", [:global])
    {complete, [partial]} = Enum.split(parts, -1)

    {lines, next} =
      Enum.map_reduce(complete, start, fn line, at ->
        line_end = at + byte_size(line) + 1
        {{line, line_end}, line_end}
      end)

    {Enum.reject(lines, fn {line, _} -> line == "" end), partial, next}
  end

  defp seq_of(line) do
    case JSON.decode(line) do
      {:ok, %{"seq" => seq}} -> seq
      _ -> nil
    end
  end

  @doc """
  The size of the run's trace now, and the last complete `seq` within that size (-1 for
  none). Read from the file's tail, so a long trace is not read whole.
  """
  @spec last_seq(run()) :: {non_neg_integer(), integer()}
  def last_seq(run) do
    path = trace_path(run.run_dir)
    size = trace_size(run.run_dir)
    {size, tail_seq(path, size, min(size, @chunk))}
  end

  defp tail_seq(_path, 0, _window), do: -1

  defp tail_seq(path, size, window) do
    with {:ok, io} <- File.open(path, [:read, :binary]),
         {:ok, tail} <- read_and_close(io, size - window, window) do
      lines = tail |> :binary.split("\n", [:global]) |> Enum.drop(-1)
      # The first line of a window that does not start the file may be cut; never trust it.
      lines = if window < size, do: Enum.drop(lines, 1), else: lines

      case Enum.reverse(lines) |> Enum.find_value(&seq_of_or_nil/1) do
        nil when window < size -> tail_seq(path, size, min(size, window * 4))
        nil -> -1
        seq -> seq
      end
    else
      _ -> -1
    end
  end

  defp seq_of_or_nil(""), do: nil

  defp seq_of_or_nil(line) do
    case seq_of(line) do
      seq when is_integer(seq) -> seq
      _ -> nil
    end
  end

  defp read_and_close(io, at, count) do
    :file.pread(io, at, count)
  after
    File.close(io)
  end

  @doc """
  One line as the event loopctl is sent: a stub when it does not decode or names another seq,
  otherwise the line made a valid contract event, with its data omitted when too large (or
  when `omit_seqs` names it) and stubbed when `stub_seqs` names it.
  """
  @spec prepare(String.t(), non_neg_integer(), run(), [integer()], [integer()]) :: map()
  def prepare(line, expected_seq, run, omit_seqs \\ [], stub_seqs \\ []) do
    case JSON.decode(line) do
      {:ok, %{"seq" => ^expected_seq} = event} ->
        cond do
          expected_seq in stub_seqs -> stub(expected_seq, run, "invalid_payload")
          expected_seq in omit_seqs -> event |> clean(run) |> omit_data()
          true -> event |> clean(run) |> fit()
        end

      _ ->
        stub(expected_seq, run, "unreadable_line")
    end
  end

  defp clean(event, run) do
    seq = event["seq"]

    %{
      "run_id" => run.run_id,
      "seq" => seq,
      "event_id" => text(event["event_id"], 128) || Integer.to_string(seq),
      "parent" => parent(event["parent"]) || root_or_under_root(seq),
      "ts" => ts(event["ts"]),
      "type" => text(event["type"], 64) || "unknown",
      "data" => data(event["data"])
    }
  end

  # Nothing of the original survives into a stub: any of its fields may be what loopctl refused,
  # and a stub refused again gives the whole run up.
  defp stub(seq, run, why) do
    %{
      "run_id" => run.run_id,
      "seq" => seq,
      "event_id" => Integer.to_string(seq),
      "parent" => root_or_under_root(seq),
      "ts" => now(),
      "type" => "trace.unshippable",
      "data" => %{"omitted" => why}
    }
  end

  # The contract allows a null parent only for the root: an event whose own parent is lost
  # hangs under the run's root event, seq 0.
  defp root_or_under_root(0), do: nil
  defp root_or_under_root(_seq), do: "0"

  defp text(value, max) when is_binary(value) do
    case value |> String.replace(<<0>>, "") |> String.slice(0, max) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value, _max), do: nil

  defp parent(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp parent(value), do: text(value, 128)

  defp ts(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> value
      _ -> now()
    end
  end

  defp ts(_value), do: now()

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp data(value) when is_map(value), do: safe(value)
  defp data(nil), do: %{}
  defp data(value), do: %{"value" => safe(value)}

  # loopctl refuses a NUL in any string or key and an integer of more digits than the byte
  # rule allows, as values it cannot store.
  defp safe(value) when is_binary(value), do: String.replace(value, <<0>>, "")

  defp safe(value) when is_integer(value) do
    if abs(value) >= Integer.pow(10, @max_digits), do: Integer.to_string(value), else: value
  end

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {safe(to_string(k)), safe(v)} end)

  defp safe(value), do: value

  defp fit(event) do
    if ByteRule.bytes(event["data"]) > @max_data_bytes or
         ByteRule.bytes(event) > @max_event_bytes,
       do: omit_data(event),
       else: event
  end

  defp omit_data(event) do
    Map.put(event, "data", %{
      "omitted" => "data_too_large",
      "data_bytes" => ByteRule.bytes(event["data"])
    })
  end

  @doc "Records that the run's trace of `trace_bytes` is fully acknowledged through `acked_seq`."
  @spec mark_done(run(), integer(), non_neg_integer()) :: :ok | {:error, term()}
  def mark_done(run, acked_seq, trace_bytes),
    do:
      write_settled(run, %{"done" => true, "acked_seq" => acked_seq, "trace_bytes" => trace_bytes})

  @doc "Records that loopctl will not take this run's trace, and why."
  @spec mark_abandoned(run(), String.t()) :: :ok | {:error, term()}
  def mark_abandoned(run, reason), do: write_settled(run, %{"abandoned" => reason})

  # Never raises: a full disk or a vanished run directory must not take the control connection
  # down with it. The caller logs the error and keeps the decision in memory.
  defp write_settled(run, fields) do
    path = settled_path(run.run_dir)
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    with :ok <- File.write(tmp, JSON.encode!(Map.put(fields, "at", at))),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp read_settled(run_dir) do
    with {:ok, raw} <- File.read(settled_path(run_dir)),
         {:ok, map} when is_map(map) <- JSON.decode(raw) do
      map
    else
      {:error, :enoent} -> nil
      # Unreadable or corrupt: treated as settled rather than reshipping blindly.
      _ -> %{"abandoned" => "unreadable trace_ship.json"}
    end
  end

  @doc "The trace file's size in bytes, 0 when there is none."
  @spec trace_bytes(run()) :: non_neg_integer()
  def trace_bytes(run), do: trace_size(run.run_dir)

  defp trace_size(run_dir) do
    case File.stat(trace_path(run_dir)) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp trace_path(run_dir), do: Path.join(run_dir, "trace.ndjson")
  defp settled_path(run_dir), do: Path.join(run_dir, "trace_ship.json")
end
