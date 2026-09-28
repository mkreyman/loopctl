defmodule LoopctlRunner.StreamEventsTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.StreamEvents

  # A recording emitter: seq numbers continue from the session's.
  defp recorder do
    {:ok, agent} = Agent.start_link(fn -> {10, []} end)

    emit = fn type, parent, data ->
      Agent.get_and_update(agent, fn {seq, events} ->
        {seq, {seq + 1, [%{seq: seq, type: type, parent: parent, data: data} | events]}}
      end)
    end

    {emit, fn -> agent |> Agent.get(&elem(&1, 1)) |> Enum.reverse() end}
  end

  defp feed(lines) do
    {emit, events} = recorder()
    _state = Enum.reduce(lines, StreamEvents.new(9), &StreamEvents.handle_line(&1, &2, emit))
    events.()
  end

  test "a subagent's messages hang off the Agent tool_use that dispatched them" do
    events =
      feed([
        ~s({"type":"system","subtype":"init","session_id":"s","model":"m","cwd":"/w","permissionMode":"auto"}),
        ~s({"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"thinking"},{"type":"tool_use","id":"toolu_A","name":"Agent"}]}}),
        ~s({"type":"assistant","parent_tool_use_id":"toolu_A","message":{"content":[{"type":"text","text":"pong"}]}}),
        ~s({"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_A"}]}}),
        ~s({"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"s"})
      ])

    assert [init, main, dispatch, sub, result_msg, result] = events
    assert init.type == "claude.system.init" and init.parent == 9
    assert init.data["cwd"] == "/w"
    assert main.type == "claude.assistant" and main.parent == 9
    assert dispatch.type == "claude.tool_use" and dispatch.parent == main.seq
    assert dispatch.data == %{"tool_use_id" => "toolu_A", "name" => "Agent"}
    assert sub.type == "claude.assistant" and sub.parent == dispatch.seq
    refute Map.has_key?(sub.data, "orphan")
    assert result_msg.parent == 9 and result_msg.data["tool_results"] == ["toolu_A"]
    assert result.type == "claude.result.success" and result.data["num_turns"] == 2
  end

  test "the last result line's subtype is kept, and nothing else sets it" do
    {emit, _events} = recorder()
    state = StreamEvents.new(9)
    assert StreamEvents.result(state) == nil

    feed = fn lines, state ->
      Enum.reduce(lines, state, &StreamEvents.handle_line(&1, &2, emit))
    end

    state =
      feed.(
        [
          ~s({"type":"result","subtype":"success","is_error":false,"num_turns":1}),
          ~s({"type":"assistant","subtype":"error_max_turns","message":{"content":[]}}),
          "not json"
        ],
        state
      )

    assert StreamEvents.result(state) == "success"

    state =
      feed.(
        [~s({"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":5})],
        state
      )

    assert StreamEvents.result(state) == "error_max_turns"
  end

  test "nested dispatches nest" do
    events =
      feed([
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"A","name":"Agent"}]}}),
        ~s({"type":"assistant","parent_tool_use_id":"A","message":{"content":[{"type":"tool_use","id":"B","name":"Agent"}]}}),
        ~s({"type":"assistant","parent_tool_use_id":"B","message":{"content":[{"type":"text"}]}})
      ])

    [_m1, a, m2, b, m3] = events
    assert m2.parent == a.seq
    assert b.parent == m2.seq
    assert m3.parent == b.seq
  end

  test "a message naming an unseen tool_use is kept and flagged, not dropped" do
    assert [%{parent: 9, data: %{"orphan" => true}}] =
             feed([
               ~s({"type":"assistant","parent_tool_use_id":"ghost","message":{"content":[]}})
             ])
  end

  test "a non-JSON line becomes an unparsed event with its size, not its content" do
    assert [%{type: "claude.unparsed", parent: 9, data: %{"bytes" => 5}}] = feed(["oops!"])
  end
end
