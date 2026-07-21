defmodule Loopctl.EgressFixtures.RawHttpCalls do
  @moduledoc """
  NEGATIVE-CONTROL fixture for the egress-chokepoint check (US-41.4, TC-41.4.5).

  Makes exactly ONE raw call per entry point `Loopctl.Egress.ChokepointScan`
  claims to detect, so the chokepoint test can point the CONFIGURABLE scanned-path
  list at this directory and assert the check FAILS on every one. A fixture living
  outside the scanned paths would make the control a no-op — which is precisely
  why the path list is configurable.

  None of these functions is ever CALLED. They exist to be parsed.
  """

  # Deliberately not registered in ChokepointScan's allowlist — the whole point is
  # that this module trips the check.

  def req_post, do: Req.post("https://example.com", [])
  def req_request, do: Req.request(url: "https://example.com")
  def req_get, do: Req.get("https://example.com")
  def req_put, do: Req.put("https://example.com")
  def req_patch, do: Req.patch("https://example.com")
  def req_delete, do: Req.delete("https://example.com")
  def req_new, do: Req.new(url: "https://example.com")
  def req_request_run, do: Req.Request.run(Req.new(url: "https://example.com"))

  def req_request_run_request,
    do: Req.Request.run_request(Req.new(url: "https://example.com"))

  def finch_request, do: Finch.request(finch_build(), Loopctl.Finch)
  def finch_build, do: Finch.build(:get, "https://example.com")
  def mint_connect, do: Mint.HTTP.connect(:https, "example.com", 443)
  def httpc_request, do: :httpc.request(~c"https://example.com")
  def gen_tcp_connect, do: :gen_tcp.connect(~c"example.com", 80, [])
  def ssl_connect, do: :ssl.connect(~c"example.com", 443, [])
end
