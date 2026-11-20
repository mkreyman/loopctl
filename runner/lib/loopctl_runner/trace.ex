defmodule LoopctlRunner.Trace do
  @moduledoc """
  The run's NDJSON event stream (design §11).

  One file per run. Every event is one JSON object on one line, shaped as the loopctl
  contract's `RunnerTraceEvent` so a shipper sends lines as they are:

      {"run_id": "<uuid>", "seq": 7, "event_id": "7", "parent": "3",
       "ts": "2026-09-12T20:36:46.485Z", "type": "claude.tool_use", "data": {...}}

  `(run_id, seq)` is the event's identity and `event_id` is `seq` as a string. `parent` is
  the parent's `event_id`, or `null` for the run's root. That link is what makes the agent
  tree reconstructable with a query instead of `bin/who-did-it.sh`: see `tree/1`.

  Traces written before this shape (no `event_id`, integer `parent`, a non-UUID run id)
  are still read and rebuilt: `read/1` normalises both fields. Such a run cannot be shipped
  under the contract, whose `run_id` is a UUID, and a shipper must skip it.

  The file on disk is the source of truth. `seq` is gapless and strictly increasing, so
  a later shipper can ACK the last contiguous seq and resume from it.
  """

  use GenServer

  @type event_id :: non_neg_integer()

  @spec start_link(String.t(), String.t()) :: GenServer.on_start()
  def start_link(path, run_id), do: GenServer.start_link(__MODULE__, {path, run_id})

  @doc "Appends an event under `parent` (a `seq`, or nil for the root) and returns its `seq`."
  @spec emit(GenServer.server(), String.t(), event_id() | nil, map()) :: event_id()
  def emit(trace, type, parent, data \\ %{}) when is_binary(type) and is_map(data) do
    GenServer.call(trace, {:emit, type, parent, data})
  end

  @doc "Flushes to disk and closes the file."
  @spec close(GenServer.server()) :: :ok
  def close(trace), do: GenServer.stop(trace, :normal)

  @doc "Reads a trace file back as a list of decoded events."
  @spec read(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, events} <- decode_lines(String.split(raw, "\n", trim: true), []) do
      {:ok, Enum.reverse(events)}
    end
  end

  defp decode_lines([], acc), do: {:ok, acc}

  defp decode_lines([line | rest], acc) do
    case JSON.decode(line) do
      {:ok, event} -> decode_lines(rest, [normalize(event) | acc])
      {:error, reason} -> {:error, {:unparseable_line, line, reason}}
    end
  end

  @doc false
  # A line written before event_id existed carries only an integer seq and parent.
  @spec normalize(map()) :: map()
  def normalize(%{"seq" => seq} = event) when is_integer(seq) do
    event
    |> Map.put_new("event_id", Integer.to_string(seq))
    |> Map.update("parent", nil, fn
      parent when is_integer(parent) -> Integer.to_string(parent)
      parent -> parent
    end)
  end

  def normalize(event), do: event

  @doc """
  Rebuilds the event tree from `parent` links.

  Returns the roots as `%{event: event, children: [...]}` nodes. An event whose parent
  is not in the trace is an error, not a silent new root: a broken link is exactly the
  defect this format exists to rule out.
  """
  @spec tree([map()]) :: {:ok, [map()]} | {:error, {:dangling_parent, map()}}
  def tree(events) do
    events = Enum.map(events, &normalize/1)
    ids = MapSet.new(events, & &1["event_id"])

    case Enum.find(events, &(&1["parent"] != nil and not MapSet.member?(ids, &1["parent"]))) do
      nil ->
        by_parent = Enum.group_by(events, & &1["parent"])
        {:ok, build(by_parent, nil)}

      dangling ->
        {:error, {:dangling_parent, dangling}}
    end
  end

  defp build(by_parent, parent) do
    by_parent
    |> Map.get(parent, [])
    |> Enum.map(&%{event: &1, children: build(by_parent, &1["event_id"])})
  end

  @doc "The last `seq` written to an existing trace file, or -1 for none."
  @spec last_seq(String.t()) :: integer()
  def last_seq(path) do
    case read(path) do
      {:ok, [_ | _] = events} -> events |> List.last() |> Map.fetch!("seq")
      _ -> -1
    end
  end

  @impl true
  def init({path, run_id}) do
    File.mkdir_p!(Path.dirname(path))
    next_seq = last_seq(path) + 1
    {:ok, io} = File.open(path, [:append, :binary])
    {:ok, %{io: io, run_id: run_id, seq: next_seq}}
  end

  @impl true
  def handle_call({:emit, type, parent, data}, _from, state) do
    event = %{
      "run_id" => state.run_id,
      "seq" => state.seq,
      "event_id" => Integer.to_string(state.seq),
      "parent" => parent && Integer.to_string(parent),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => type,
      "data" => data
    }

    :ok = IO.binwrite(state.io, [JSON.encode!(event), "\n"])
    {:reply, state.seq, %{state | seq: state.seq + 1}}
  end

  @impl true
  def terminate(_reason, state) do
    :file.datasync(state.io)
    File.close(state.io)
  end
end
