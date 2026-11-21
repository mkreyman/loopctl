defmodule LoopctlE2e.McpTest do
  @moduledoc """
  The stdio client against a fake MCP server (test/support/fake_mcp.mjs): the JSON-RPC
  framing, the env and cwd a session starts with, an error result, a timeout and a SIGKILL.
  Needs node on PATH, as the live scenario does.
  """
  use ExUnit.Case, async: true

  alias LoopctlE2e.Mcp

  @fake Path.expand("../support/fake_mcp.mjs", __DIR__)

  setup %{} do
    node = System.find_executable("node") || flunk("node is not on PATH")
    {:ok, node: node}
  end

  defp start(ctx, env \\ []) do
    {:ok, pid} =
      Mcp.start(
        node: ctx.node,
        index: @fake,
        cwd: ctx.tmp_dir,
        env: [{"CLAUDE_SESSION_ID", "e2e-a-r1"} | env]
      )

    on_exit(fn -> Mcp.stop(pid) end)
    pid
  end

  @tag :tmp_dir
  test "a call returns the decoded first content block, run in the session's cwd and env",
       ctx do
    # HOME is inherited from this process; a false value unsets it in the session.
    pid = start(ctx, [{"HOME", false}])

    assert {:ok, body} = Mcp.call(pid, "get_story", %{story_id: "s1"})
    assert body["args"] == %{"story_id" => "s1"}
    assert body["session"] == "e2e-a-r1"
    assert body["cwd"] == ctx.tmp_dir
    assert body["home"] == nil

    # Ids advance: a second call is answered too.
    assert {:ok, %{"args" => %{"n" => 2}}} = Mcp.call(pid, "x", %{n: 2})
  end

  @tag :tmp_dir
  test "an isError result is an error carrying the decoded body", ctx do
    pid = start(ctx)
    assert {:error, %{"error" => true, "body" => %{"args" => %{}}}} = Mcp.call(pid, "fail")
  end

  @tag :tmp_dir
  test "a server that never answers times the call out without stopping the client", ctx do
    pid = start(ctx)
    assert {:error, :timeout} = Mcp.call(pid, "hang", %{}, 200)
    assert {:ok, _} = Mcp.call(pid, "x")
  end

  @tag :tmp_dir
  test "kill ends the process at once, and later calls answer exited", ctx do
    pid = start(ctx)
    assert :ok = Mcp.kill(pid)
    assert {:error, {:exited, _}} = Mcp.call(pid, "x")
    assert :ok = Mcp.stop(pid)
  end
end
