defmodule Loopctl.Webhooks.ReqDeliveryTest do
  @moduledoc """
  Tests the SSRF egress guard on the webhook delivery path
  (ie-02 / GHSA-jh42-wf7g-f5rg): re-validation at delivery time and
  `redirect: false`.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Webhooks.ReqDelivery

  describe "deliver/3 re-validates the URL (DNS rebinding / TOCTOU)" do
    test "refuses a metadata IPv4 literal without making a request" do
      assert {:error, message} =
               ReqDelivery.deliver("http://169.254.169.254/latest/meta-data/", "{}", [])

      assert message =~ "blocked_url"
    end

    test "refuses a Fly 6PN IPv6 literal" do
      assert {:error, message} = ReqDelivery.deliver("http://[fdaa::1]/x", "{}", [])
      assert message =~ "blocked_url"
    end

    test "refuses a hostname that now resolves to a private address" do
      expect(Loopctl.MockDnsResolver, :resolve, fn _host ->
        {:ok, [{10, 0, 0, 1}]}
      end)

      assert {:error, message} =
               ReqDelivery.deliver("https://rebind.example.com/hooks", "{}", [])

      assert message =~ "blocked_url"
    end
  end

  describe "deliver/3 does not follow redirects" do
    test "a 302 to an internal target is NOT followed (redirect: false)" do
      # Public IP literal passes the guard (no DNS). The plug returns a 302 whose
      # Location points at the metadata IP. With redirect: false the 302 is
      # returned as-is (a non-2xx), so delivery fails instead of silently hopping
      # to 169.254.169.254 and reading it back.
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/")
        |> Plug.Conn.send_resp(302, "redirecting")
      end)

      assert {:error, message} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [])

      assert message =~ "302"
    end
  end

  describe "deliver/3 happy path" do
    test "delivers to a public URL" do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [])
    end
  end
end
