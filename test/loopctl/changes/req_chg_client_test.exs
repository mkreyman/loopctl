defmodule Loopctl.Changes.ReqChgClientTest do
  @moduledoc """
  US-47.3: the real gap-pull client against `Req.Test` — the signed string, the URL and the
  response mapping (`config :loopctl, :chg_req_plug` routes it here in test).
  """

  use ExUnit.Case, async: true

  alias Loopctl.Changes.ReqChgClient
  alias Loopctl.Changes.Signature

  @secret String.duplicate("s", 32)

  test "signs \"<timestamp>.GET.<path>?<query>\" exactly as sent" do
    Req.Test.stub(ReqChgClient, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "chg.test"
      assert conn.request_path == "/api/v1/changes/01JAXYZ/events"
      assert conn.query_string == "after=7"

      [ts] = Plug.Conn.get_req_header(conn, "x-chg-timestamp")
      [sig] = Plug.Conn.get_req_header(conn, "x-chg-signature")
      assert abs(String.to_integer(ts) - System.os_time(:second)) < 5

      assert sig ==
               Signature.header(@secret, "#{ts}.GET./api/v1/changes/01JAXYZ/events?after=7")

      Req.Test.json(conn, %{"events" => [%{"event_seq" => 8}], "next_after" => nil})
    end)

    assert {:ok, [%{"event_seq" => 8}]} =
             ReqChgClient.events_after("https://chg.test/", @secret, "01JAXYZ", 7)
  end

  test "a caught-up pull is an empty events list; a bare array is not the contract" do
    Req.Test.stub(ReqChgClient, &Req.Test.json(&1, %{"events" => [], "next_after" => nil}))
    assert {:ok, []} = ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)

    Req.Test.stub(ReqChgClient, &Req.Test.json(&1, [%{"event_seq" => 1}]))

    assert {:error, :invalid_response} =
             ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)
  end

  test "404 is :unknown_change" do
    Req.Test.stub(ReqChgClient, &Plug.Conn.send_resp(&1, 404, ~s({"error":"not_found"})))

    assert {:error, :unknown_change} =
             ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)
  end

  test "401 is :unauthorized; any other status or body is a transient error" do
    Req.Test.stub(ReqChgClient, &Plug.Conn.send_resp(&1, 401, "no"))

    assert {:error, :unauthorized} =
             ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)

    Req.Test.stub(ReqChgClient, &Plug.Conn.send_resp(&1, 503, "down"))

    assert {:error, {:chg_server_error, 503}} =
             ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)

    Req.Test.stub(ReqChgClient, &Req.Test.json(&1, %{"unexpected" => true}))

    assert {:error, :invalid_response} =
             ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)
  end

  test "a transport failure is unreachable, not a crash" do
    Req.Test.stub(ReqChgClient, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:chg_server_unreachable, Req.TransportError}} =
             ReqChgClient.events_after("https://chg.test", @secret, "C1", 0)
  end
end
