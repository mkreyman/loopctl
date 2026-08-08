defmodule Loopctl.Webhooks.ReqDeliveryTest do
  @moduledoc """
  The egress guard on the webhook delivery path.

  Two layers, both exercised here:

    * the SSRF denylist (ie-02 / GHSA-jh42-wf7g-f5rg) — re-validation at delivery
      time and `redirect: false`. Since US-41.5 it is enforced through the ONE
      policy (`Egress.Policy.check/4`, `tenant_supplied: true`) rather than a bare
      `UrlGuard.pin/1`, so these tests pin the SEMANTICS, not the call;
    * the US-41.5 locality decision — refusals are `{:refused, {tag, details}}`,
      never `{:error, _}`, so a caller can tell a configuration conflict from a
      delivery failure.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope
  alias Loopctl.Test.AllowlistSource
  alias Loopctl.Webhooks.ReqDelivery

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)
    {:ok, tenant: tenant, scope: Scope.new(tenant.id)}
  end

  defp with_allowlist(entries, fun) do
    AllowlistSource.put(entries)

    try do
      fun.()
    after
      AllowlistSource.clear()
    end
  end

  describe "deliver/4 re-validates the URL (DNS rebinding / TOCTOU)" do
    test "refuses a metadata IPv4 literal without making a request", %{scope: scope} do
      assert {:refused, {:egress_blocked, details}} =
               ReqDelivery.deliver("http://169.254.169.254/latest/meta-data/", "{}", [], scope)

      assert details.verdict == :denylisted
      assert Egress.block_kind({:egress_blocked, details}) == :ssrf_denied
    end

    test "refuses a Fly 6PN IPv6 literal", %{scope: scope} do
      assert {:refused, {:egress_blocked, %{verdict: :denylisted}}} =
               ReqDelivery.deliver("http://[fdaa::1]/x", "{}", [], scope)
    end

    test "refuses a hostname that now resolves to a private address", %{scope: scope} do
      expect(Loopctl.MockDnsResolver, :resolve, fn _host ->
        {:ok, [{10, 0, 0, 1}]}
      end)

      assert {:refused, {:egress_blocked, %{verdict: :denylisted}}} =
               ReqDelivery.deliver("https://rebind.example.com/hooks", "{}", [], scope)
    end

    # A tenant-supplied destination must NEVER degrade to an unpinned,
    # redirect-following request when classification fails — and the refusal must
    # be the TRANSIENT one, since a resolve failure is a blip, not a config state.
    test "an unresolvable destination fails CLOSED as TRANSIENT", %{scope: scope} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> {:error, :nxdomain} end)

      assert {:refused, {:egress_unavailable, _details} = refusal} =
               ReqDelivery.deliver("https://who-knows.example.com/hooks", "{}", [], scope)

      assert Egress.block_kind(refusal) == :transient
    end
  end

  describe "deliver/4 does not follow redirects" do
    test "a 302 to an internal target is NOT followed (redirect: false)", %{scope: scope} do
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
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [], scope)

      assert message =~ "302"
    end
  end

  describe "deliver/4 happy path" do
    test "delivers to a public URL", %{scope: scope} do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [], scope)
    end

    test "a legit hostname-based delivery still succeeds through the pinned path", %{scope: scope} do
      # Resolve ONCE to a public IP; the connection is pinned to that IP while the
      # original host is preserved for Host/SNI/cert (proves pinning didn't break
      # normal delivery).
      expect(Loopctl.MockDnsResolver, :resolve, 1, fn "hooks.example.com" ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} =
               ReqDelivery.deliver("https://hooks.example.com/hooks", "{}", [], scope)
    end
  end

  describe "operator-plane delivery (scope: nil)" do
    # The scale-alert webhook. No tenant marking applies, but the SSRF denylist
    # still does — the same UrlGuard primitive the policy composes.
    test "still refuses a denylisted destination" do
      assert {:error, message} =
               ReqDelivery.deliver("http://169.254.169.254/alert", "{}", [], nil)

      assert message =~ "blocked_url"
    end

    test "delivers to a public URL" do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} =
               ReqDelivery.deliver("https://93.184.216.34/alert", "{}", [], nil)
    end
  end

  describe "the operator allowlist is the ONLY carve-out for a private destination" do
    test "a WEBHOOK-granting allowlist entry makes a loopback destination deliverable",
         %{scope: scope} do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      with_allowlist(["127.0.0.1@webhook"], fn ->
        assert {:ok, %{status: 200}} =
                 ReqDelivery.deliver("http://127.0.0.1:9000/hooks", "{}", [], scope)
      end)
    end

    test "the SAME private host WITHOUT an allowlist entry is still refused", %{scope: scope} do
      assert {:refused, {:egress_blocked, %{verdict: :denylisted}}} =
               ReqDelivery.deliver("http://127.0.0.1:9000/hooks", "{}", [], scope)
    end

    # A carve-out is the operator saying WHAT the deployment reaches this host FOR.
    # An entry made for the deployment's model endpoint must not also make that
    # host a destination for tenant-authored payloads: the URL here is written by
    # a tenant, the entry was written by the operator, and they were answering
    # different questions.
    test "an INFERENCE-only entry does not make the host a webhook destination",
         %{scope: scope} do
      with_allowlist(["127.0.0.1@inference"], fn ->
        assert {:refused, {:egress_blocked, %{verdict: :denylisted}}} =
                 ReqDelivery.deliver("http://127.0.0.1:9000/hooks", "{}", [], scope)
      end)
    end

    # An UNQUALIFIED entry is inference-only, so it behaves like the case above.
    test "an UNQUALIFIED entry does not make the host a webhook destination",
         %{scope: scope} do
      with_allowlist(["127.0.0.1"], fn ->
        assert {:refused, {:egress_blocked, %{verdict: :denylisted}}} =
                 ReqDelivery.deliver("http://127.0.0.1:9000/hooks", "{}", [], scope)
      end)
    end

    # The carve-out is bound to what the operator wrote: naming a port grants
    # THAT port, not the host.
    test "a port-bound entry does not deliver to a different port on the same host",
         %{scope: scope} do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      with_allowlist(["127.0.0.1:9000@webhook"], fn ->
        assert {:ok, %{status: 200}} =
                 ReqDelivery.deliver("http://127.0.0.1:9000/hooks", "{}", [], scope)

        assert {:refused, {:egress_blocked, %{verdict: :denylisted}}} =
                 ReqDelivery.deliver("http://127.0.0.1:9001/hooks", "{}", [], scope)
      end)
    end
  end

  describe "a failed delivery describes the failure, not the response" do
    test "the stored error carries the status and content-type, never the body",
         %{scope: scope} do
      secret = "s3cr3t-token-from-an-internal-service"

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(403, secret)
      end)

      assert {:error, message} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [], scope)

      assert message =~ "403"
      assert message =~ "text/plain"
      refute message =~ secret
    end

    # The header VALUE is chosen by the destination too. The error string is
    # persisted and read back through the deliveries API, so an unbounded copy
    # would let a hostile receiver inflate that column at will.
    test "a hostile content-type is TRUNCATED, not stored whole", %{scope: scope} do
      padding = String.duplicate("a", 4_000)

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/#{padding}")
        |> Plug.Conn.send_resp(500, "")
      end)

      assert {:error, message} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [], scope)

      assert message =~ "500"
      assert String.length(message) < 200
    end

    # REGRESSION (review): the bound was applied to the content-type fragment
    # only, while the sibling transport/exception branches build their string from
    # `inspect/1` of a peer-influenced term and write the SAME persisted column
    # through the same deliveries API.
    test "a destination-shaped transport failure is bounded too", %{scope: scope} do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.transport_error(conn, {:bad_alpn_protocol, String.duplicate("z", 4_000)})
      end)

      assert {:error, message} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [], scope)

      assert message =~ "connection_error"
      assert String.length(message) < 400
    end

    test "a body-less failure still reports the status", %{scope: scope} do
      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert {:error, message} =
               ReqDelivery.deliver("https://93.184.216.34/hooks", "{}", [], scope)

      assert message =~ "500"
    end
  end
end
