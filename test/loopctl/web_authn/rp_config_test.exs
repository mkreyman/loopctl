defmodule Loopctl.WebAuthn.RpConfigTest do
  @moduledoc """
  #511 — the WebAuthn relying-party env resolution lived inline in the prod block of
  `config/runtime.exs`, where no test can reach it: a blank `WEBAUTHN_RP_ID` set
  `rp_id: ""` and broke every enrollment ceremony while the release booted clean. These
  are the rules that regression guards, as pure functions.
  """
  use ExUnit.Case, async: true

  alias Loopctl.WebAuthn.RpConfig

  describe "resolve/1 — unset and blank values leave config.exs untouched" do
    test "all unset resolves to no opts and no warnings" do
      assert RpConfig.resolve([]) == {[], []}
      assert RpConfig.resolve(rp_id: nil, rp_name: nil, origin: nil, phx_host: nil) == {[], []}
    end

    test "a blank or whitespace value is treated as unset, not as an empty string" do
      assert {opts, []} = RpConfig.resolve(rp_id: "", rp_name: "   ", origin: "\n")
      assert opts == []
    end

    test "values are trimmed" do
      assert {opts, []} = RpConfig.resolve(rp_id: " example.com ", rp_name: " loopy ")
      assert opts[:rp_id] == "example.com"
      assert opts[:rp_name] == "loopy"
    end
  end

  describe "resolve/1 — rp_id shape" do
    test "accepts bare hosts" do
      for host <- ~w(example.com wiki.example.com a.b.c.example.com localhost my-host.example) do
        assert {opts, []} = RpConfig.resolve(rp_id: host, origin: "https://#{host}")
        assert opts[:rp_id] == host
      end
    end

    test "rejects schemes, ports, paths, whitespace and degenerate label-less hosts" do
      for bad <- [
            "https://wiki.example.com",
            "example.com:443",
            "example.com/x",
            "a b",
            ".",
            "..",
            "-",
            "example..com",
            "-example.com"
          ] do
        assert {opts, [warning]} = RpConfig.resolve(rp_id: bad)
        refute Keyword.has_key?(opts, :rp_id)
        assert warning =~ "WEBAUTHN_RP_ID"
        assert warning =~ bad
      end
    end
  end

  describe "resolve/1 — origin shape" do
    test "accepts scheme://host[:port]" do
      for origin <- [
            "https://wiki.example.com",
            "http://localhost:4000",
            "https://example.com:8443"
          ] do
        assert {opts, _} = RpConfig.resolve(origin: origin)
        assert opts[:origin] == origin
      end
    end

    test "rejects a missing scheme, a trailing slash or a path — Wax compares the origin verbatim" do
      for bad <- [
            "wiki.example.com",
            "https://wiki.example.com/",
            "https://wiki.example.com/signup"
          ] do
        assert {opts, warnings} = RpConfig.resolve(rp_id: "wiki.example.com", origin: bad)
        refute Keyword.has_key?(opts, :origin)
        assert Enum.any?(warnings, &(&1 =~ "WEBAUTHN_ORIGIN" and &1 =~ bad))
      end
    end
  end

  describe "resolve/1 — origin default" do
    test "defaults to https://$PHX_HOST whether or not WEBAUTHN_RP_ID is set" do
      assert {opts, _} = RpConfig.resolve(phx_host: "app.example.com")
      assert opts[:origin] == "https://app.example.com"

      assert {opts, []} = RpConfig.resolve(rp_id: "example.com", phx_host: "app.example.com")
      assert opts[:origin] == "https://app.example.com"
    end

    test "derives nothing when PHX_HOST is unset, rather than from its example.com placeholder" do
      assert {opts, _} = RpConfig.resolve(rp_id: "wiki.example.com", phx_host: nil)
      refute Keyword.has_key?(opts, :origin)
    end

    test "an explicit WEBAUTHN_ORIGIN wins over PHX_HOST" do
      assert {opts, _} =
               RpConfig.resolve(
                 origin: "https://public.example.com",
                 phx_host: "internal.fly.dev"
               )

      assert opts[:origin] == "https://public.example.com"
    end
  end

  describe "resolve/1 — rp_id/origin pairing" do
    test "warns when the rp_id is not a registrable suffix of the origin" do
      assert {_opts, [warning]} =
               RpConfig.resolve(rp_id: "other.example", origin: "https://wiki.example.com")

      assert warning =~ "other.example"
      assert warning =~ "https://wiki.example.com"
    end

    test "a parent-domain rp_id is legal and warns about nothing" do
      assert {_opts, []} =
               RpConfig.resolve(rp_id: "example.com", origin: "https://app.example.com")
    end

    test "warns when an origin is set without an rp_id, since the compiled default applies" do
      assert {_opts, [warning]} = RpConfig.resolve(origin: "https://wiki.example.com")
      assert warning =~ "WEBAUTHN_RP_ID"
    end

    test "a derived origin alone does not warn — that is the hosted deployment" do
      assert {_opts, []} = RpConfig.resolve(phx_host: "loopctl.com")
    end
  end
end
