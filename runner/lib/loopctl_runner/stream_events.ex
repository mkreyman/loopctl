defmodule LoopctlRunner.StreamEvents do
  @moduledoc """
  Maps `claude -p --output-format stream-json` lines onto parent-linked trace events.

  The raw stdout is kept verbatim beside the trace (`stdout.ndjson`); the trace carries
  small structured events whose `parent` rebuilds the agent tree:

      session.started
      └─ claude.assistant                (main thread)
         └─ claude.tool_use  name=Agent  (the dispatch)
            └─ claude.assistant          (the subagent's own messages)

  The link is the CLI's own `parent_tool_use_id`, which it stamps on every message a
  subagent produces (measured on 2.1.270). A message naming a tool_use this parser has
  not seen hangs off the session and is flagged `orphan: true` rather than dropped.
  """

  @type emit_fun :: (String.t(), non_neg_integer() | nil, map() -> non_neg_integer())
  @type state :: %{
          session: non_neg_integer(),
          tool_uses: %{optional(String.t()) => integer()},
          result: String.t() | nil,
          turns: non_neg_integer() | nil
        }

  # The largest turn count `RunnerSessionEnded.turns_used` carries (contract 1.27.0).
  @max_turns 2_147_483_647

  @spec new(non_neg_integer()) :: state()
  def new(session_seq), do: %{session: session_seq, tool_uses: %{}, result: nil, turns: nil}

  @doc """
  The `num_turns` of the last `result` line the CLI printed — the agent turns the session took,
  which `session_ended` carries as `turns_used` (contract 1.27.0) — or nil before one, or when
  that line carries no count the contract can hold (a non-negative integer up to 2^31 - 1).
  """
  @spec turns(state()) :: non_neg_integer() | nil
  def turns(%{turns: turns}), do: turns

  @doc """
  The `subtype` of the last `result` line the CLI printed, or nil before one: its own statement
  of why it stopped (`success`, `error_max_turns`, ...), which `LoopctlRunner.Session` reads to
  tell a session that ran out of turns from one that failed.
  """
  @spec result(state()) :: String.t() | nil
  def result(%{result: result}), do: result

  @doc "Handles one complete stdout line."
  @spec handle_line(binary(), state(), emit_fun()) :: state()
  def handle_line(line, state, emit) do
    case JSON.decode(line) do
      {:ok, %{"type" => type} = message} when is_binary(type) ->
        handle_message(message, state, emit)

      _ ->
        emit.("claude.unparsed", state.session, %{"bytes" => byte_size(line)})
        state
    end
  end

  defp handle_message(message, state, emit) do
    {parent, orphan?} = parent_for(message, state)
    data = summarize(message) |> put_orphan(orphan?)
    seq = emit.(event_type(message), parent, data)
    message |> register_tool_uses(seq, state, emit) |> note_result(message)
  end

  defp note_result(state, %{"type" => "result"} = message) do
    state = %{state | turns: turn_count(message["num_turns"])}

    case message["subtype"] do
      subtype when is_binary(subtype) -> %{state | result: subtype}
      _ -> state
    end
  end

  defp note_result(state, _message), do: state

  defp turn_count(n) when is_integer(n) and n >= 0 and n <= @max_turns, do: n
  defp turn_count(_n), do: nil

  defp parent_for(%{"parent_tool_use_id" => id}, state) when is_binary(id) do
    case Map.fetch(state.tool_uses, id) do
      {:ok, seq} -> {seq, false}
      :error -> {state.session, true}
    end
  end

  defp parent_for(_message, state), do: {state.session, false}

  defp put_orphan(data, true), do: Map.put(data, "orphan", true)
  defp put_orphan(data, false), do: data

  defp event_type(%{"type" => type, "subtype" => subtype}) when is_binary(subtype),
    do: "claude.#{type}.#{subtype}"

  defp event_type(%{"type" => type}), do: "claude.#{type}"

  # Each tool_use block becomes its own child event, so a later message carrying that
  # tool_use id as its parent_tool_use_id attaches beneath the dispatch itself.
  defp register_tool_uses(message, message_seq, state, emit) do
    message
    |> content_blocks()
    |> Enum.filter(&(&1["type"] == "tool_use" and is_binary(&1["id"])))
    |> Enum.reduce(state, fn block, acc ->
      data = %{"tool_use_id" => block["id"], "name" => block["name"]}
      seq = emit.("claude.tool_use", message_seq, data)
      %{acc | tool_uses: Map.put(acc.tool_uses, block["id"], seq)}
    end)
  end

  defp content_blocks(%{"message" => %{"content" => blocks}}) when is_list(blocks),
    do: Enum.filter(blocks, &is_map/1)

  defp content_blocks(_), do: []

  @result_keys ~w(is_error num_turns duration_ms total_cost_usd stop_reason terminal_reason)

  defp summarize(%{"type" => "result"} = message) do
    message
    |> Map.take(@result_keys)
    |> Map.put("session_id", message["session_id"])
    |> maybe_put("usage", message["usage"])
  end

  defp summarize(%{"type" => "system", "subtype" => "init"} = message) do
    %{
      "session_id" => message["session_id"],
      "model" => message["model"],
      "cwd" => message["cwd"],
      "permission_mode" => message["permissionMode"]
    }
  end

  defp summarize(message) do
    blocks = content_blocks(message)

    %{}
    |> maybe_put("parent_tool_use_id", message["parent_tool_use_id"])
    |> maybe_put("blocks", block_types(blocks))
    |> maybe_put("tool_results", tool_result_ids(blocks))
  end

  defp block_types([]), do: nil
  defp block_types(blocks), do: Enum.map(blocks, & &1["type"])

  defp tool_result_ids(blocks) do
    case for(%{"type" => "tool_result", "tool_use_id" => id} <- blocks, do: id) do
      [] -> nil
      ids -> ids
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
