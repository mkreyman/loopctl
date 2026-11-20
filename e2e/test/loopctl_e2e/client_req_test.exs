defmodule LoopctlE2e.Client.ReqTest do
  @moduledoc """
  The live client speaks loopctl's witness protocol. The first live run failed at its first
  loopctl call with `412 witness_header_missing`, because the client sent no witness header.
  A scripted requester stands in for `Req.request/1` and records the headers of every
  request.
  """
  use ExUnit.Case, async: true

  alias LoopctlE2e.Client.Req, as: Live

  @env %{"LOOPCTL_E2E_ORCH_KEY" => "orch", "E2E_GITHUB_TOKEN" => "gh"}
  @sth "41:AAAAAAAAAAAAAAAAAAAAAA"
  @newer "42:BBBBBBBBBBBBBBBBBBBBBB"

  # Answers each request with the next scripted response and sends the request's headers
  # back to the test.
  defp client(responses) do
    test = self()
    {:ok, script} = Agent.start_link(fn -> responses end)

    requester = fn opts ->
      send(test, {:headers, Map.new(opts[:headers])})
      {:ok, Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)}
    end

    {:ok, {Live, conn}} = Live.from_env(@env, requester: requester)
    conn
  end

  defp resp(status, body, sth \\ nil) do
    headers = if sth, do: %{"x-loopctl-current-sth" => [sth]}, else: %{}
    %Req.Response{status: status, body: body, headers: headers}
  end

  @spent %{"error" => %{"code" => "witness_bootstrap_already_consumed"}}

  test "the first loopctl request asks for the bootstrap; later ones echo the STH it got" do
    conn = client([resp(200, %{"data" => []}, @sth), resp(200, %{"data" => []}, @newer)])

    assert {:ok, 200, _} = Live.get(conn, :loopctl, "/api/v1/stories", %{})
    assert_received {:headers, %{"x-loopctl-sth-bootstrap" => "true"} = first}
    refute Map.has_key?(first, "x-loopctl-last-known-sth")

    assert {:ok, 200, _} = Live.get(conn, :loopctl, "/api/v1/stories", %{})
    assert_received {:headers, %{"x-loopctl-last-known-sth" => @sth}}
  end

  test "a spent bootstrap grace is retried once with the STH the 412 carried" do
    conn = client([resp(412, @spent, @sth), resp(201, %{"ok" => true})])

    assert {:ok, 201, %{"ok" => true}} = Live.post(conn, :loopctl, "/api/v1/x", %{})
    assert_received {:headers, %{"x-loopctl-sth-bootstrap" => "true"}}
    assert_received {:headers, %{"x-loopctl-last-known-sth" => @sth}}
  end

  test "the retry happens once, and a 412 with no STH is not retried" do
    conn = client([resp(412, @spent, @sth), resp(412, @spent, @sth)])
    assert {:ok, 412, @spent} = Live.get(conn, :loopctl, "/api/v1/x", %{})
    assert_received {:headers, _}
    assert_received {:headers, _}
    refute_received {:headers, _}

    conn = client([resp(412, %{"error" => %{"code" => "witness_header_missing"}})])
    assert {:ok, 412, _} = Live.get(conn, :loopctl, "/api/v1/x", %{})
  end

  test "a divergence 409 is not retried, but its STH is used by the next request" do
    conn =
      client([resp(409, %{"error" => %{"code" => "witness_divergence"}}, @newer), resp(200, %{})])

    assert {:ok, 409, _} = Live.get(conn, :loopctl, "/api/v1/x", %{})
    assert {:ok, 200, _} = Live.get(conn, :loopctl, "/api/v1/x", %{})
    assert_received {:headers, _}
    assert_received {:headers, %{"x-loopctl-last-known-sth" => @newer}}
  end

  test "GitHub requests carry no witness header" do
    conn = client([resp(200, %{}, @sth)])
    assert {:ok, 200, _} = Live.get(conn, :github, "/repos/a/b", %{})
    assert_received {:headers, headers}
    refute Map.has_key?(headers, "x-loopctl-sth-bootstrap")
    refute Map.has_key?(headers, "x-loopctl-last-known-sth")
  end
end
