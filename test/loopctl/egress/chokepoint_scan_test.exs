defmodule Loopctl.Egress.ChokepointScanTest do
  @moduledoc """
  TC-41.4.5 — the chokepoint is MANDATORY, not conventional.

  Proves the control in BOTH directions: it FAILS on every detected entry point
  in a fixture module inside the CONFIGURED scanned-path list, and it PASSES on
  `lib/` as shipped. A fixture living outside the scanned paths would make this
  control a no-op, which is exactly why the path list is configurable.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Egress.ChokepointScan

  @fixture_path "test/support/egress_fixtures"

  describe "negative control — the check FAILS on every entry point" do
    setup do
      {:ok, violations: ChokepointScan.scan([@fixture_path])}
    end

    # Every entry point AC-41.4.4 (i) enumerates.
    for call <- [
          "Req.post",
          "Req.request",
          "Req.get",
          "Req.put",
          "Req.patch",
          "Req.delete",
          "Req.new",
          "Req.Request.run",
          "Req.Request.run_request",
          "Finch.request",
          "Finch.build",
          "Mint.HTTP.connect",
          ":httpc.request",
          ":gen_tcp.connect",
          ":ssl.connect",
          # BANG variants — Req's idiomatic default, and the most likely way a
          # future contributor adds a direct outbound call.
          "Req.post!",
          "Req.request!",
          "Req.get!",
          "Req.put!",
          "Req.patch!",
          "Req.delete!",
          "Finch.request!"
        ] do
      test "flags #{call}", %{violations: violations} do
        assert Enum.any?(violations, &(&1.call == unquote(call))),
               "expected #{unquote(call)} to be flagged; got: " <>
                 inspect(Enum.map(violations, & &1.call))
      end
    end

    test "attributes each violation to the fixture module and a line", %{violations: violations} do
      assert violations != []

      assert Enum.all?(violations, fn v ->
               v.module == "Loopctl.EgressFixtures.RawHttpCalls" and v.line > 0 and
                 v.file =~ @fixture_path
             end)
    end

    # REGRESSION (review): `detect/2` matched only literal alias heads, so
    # `alias Req, as: Http; Http.post(...)`, `alias Req.Request; Request.run(...)`
    # and `apply(Req, :post, [...])` all passed CI silently — and aliasing is the
    # idiomatic way to add a call to a module that already aliases things.
    test "an ALIASED Req call is flagged, not evaded", %{violations: violations} do
      calls = Enum.map(violations, & &1.call)

      # `Http.post/2` resolves to Req.post through the file's alias table.
      assert Enum.count(calls, &(&1 == "Req.post")) >= 2
      assert Enum.count(calls, &(&1 == "Req.Request.run")) >= 2
    end

    test "a literal apply/3 dispatch is flagged", %{violations: violations} do
      assert Enum.any?(Enum.map(violations, & &1.call), &(&1 == "apply/3 -> Req.post"))
    end

    test "the message names the wrapper and the escape hatch", %{violations: violations} do
      message = violations |> hd() |> ChokepointScan.message()
      assert message =~ "Loopctl.Provider.post/3"
      assert message =~ "ChokepointScan"
    end
  end

  describe "positive control — the check PASSES on lib/ as shipped" do
    test "no direct outbound HTTP outside the wrapper's explicit allowlist" do
      violations = ChokepointScan.scan(["lib"])

      assert violations == [],
             "direct outbound HTTP found outside the chokepoint:\n" <>
               Enum.map_join(
                 violations,
                 "\n",
                 &"  #{&1.file}:#{&1.line} #{&1.call} (#{&1.module})"
               )
    end

    test "the default scanned-path list is lib/, and it is configurable" do
      assert ChokepointScan.default_paths() == ["lib"]
    end
  end

  describe "allowlist" do
    test "the wrapper itself is allowlisted" do
      assert Map.has_key?(ChokepointScan.allowed(), "Loopctl.Provider")
    end

    test "every allowlisted module carries a non-empty justification" do
      for {module, justification} <- ChokepointScan.allowed() do
        assert is_binary(justification) and byte_size(justification) > 30,
               "#{module} needs a real justification, not a rubber stamp"
      end
    end

    test "the known-unguarded call sites are named explicitly, not silently missed" do
      allowed = ChokepointScan.allowed()

      # These three are the sites Admission itself misses today. Naming them here
      # is the point: the gap is DOCUMENTED, not invisible.
      assert Map.has_key?(allowed, "Loopctl.Webhooks.ReqDelivery")
      assert allowed["Loopctl.Webhooks.ReqDelivery"] =~ "US-41.5"
      assert Map.has_key?(allowed, "Loopctl.Verification.GitHubActions")
      assert Map.has_key?(allowed, "Loopctl.Secrets.FlyAdapter")
    end
  end

  describe "residual gap is stated, not implied away" do
    test "the moduledoc names both uncovered surfaces" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(ChokepointScan)

      assert doc =~ "inside a dependency"
      assert doc =~ "mcp-server"
      # The alias-evasion gap was closed; the RUNTIME-computed-module gap replaces
      # it in the disclosure, so the wording stays honest about what is proven.
      assert doc =~ "computed at runtime"
      assert doc =~ "every outbound HTTP call made by loopctl application code"
    end
  end
end
