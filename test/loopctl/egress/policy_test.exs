defmodule Loopctl.Egress.PolicyTest do
  @moduledoc """
  US-41.4 — the single egress policy: locality classification (AC-41.4.5 /
  AC-41.4.9), fail-closed refusal (AC-41.4.3), and the pin cache's tenant
  scoping / invalidation / `:pin_stale` recovery (AC-41.4.12, TC-41.4.14).
  """

  use Loopctl.DataCase, async: true

  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Test.AllowlistSource

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)
    {:ok, tenant: tenant, scope: Scope.new(tenant.id)}
  end

  defp mark_local_only(tenant_id, project_id \\ nil) do
    {:ok, _} = Egress.enable_local_only(tenant_id, project_id, acknowledge: true)
    PinCache.invalidate_tenant(tenant_id)
    :ok
  end

  describe "default-off (AC-41.4.12)" do
    # AC-41.4.12 verbatim: "for non-local_only scopes on vendor defaults the policy
    # re-resolves normally and PINS PER REQUEST at connect time". Default-off is
    # about the REFUSAL, not about dropping the TOCTOU pin.
    test "an unmarked scope is ALLOWED and pinned per request", %{scope: scope} do
      assert {:ok, %{host: "api.openai.com", ip: _ip, uri: %URI{}}} =
               Policy.check(scope, "https://api.openai.com/v1/embeddings", :inference)
    end

    test "an unmarked scope needs no probe and no refusal, and its pin is CACHED",
         %{scope: scope} do
      assert {:ok, pinned} =
               Policy.check(scope, "https://api.anthropic.com/v1/messages", :inference)

      assert pinned.host == "api.anthropic.com"

      # AC-41.4.12 bounds the hot path at ONE CHEAP CLASSIFICATION with no network
      # or DB round-trip — and the default path IS 100% of existing traffic. The pin
      # therefore comes from the same cached entry the local_only path uses;
      # resolving per request would put two uncached DNS lookups in front of every
      # provider call AND change the Finch pool key whenever a CDN-fronted vendor
      # host rotated its answer, collapsing connection reuse.
      assert {:ok, _entry} =
               PinCache.fetch(scope.tenant_id, Scope.key(scope), "api.anthropic.com")

      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> raise "hot path resolved DNS" end)

      assert {:ok, %{host: "api.anthropic.com"}} =
               Policy.check(scope, "https://api.anthropic.com/v1/messages", :inference)
    end

    # The pin is a TOCTOU control, not a locality decision: an unpinnable host must
    # NOT hand a default (unmarked) scope a brand-new failure mode.
    test "an unmarked scope whose host cannot be pinned proceeds UNPINNED", %{scope: scope} do
      assert {:ok, :unpinned} = Policy.check(scope, "https://127.0.0.1/v1/embeddings", :inference)
    end

    # US-41.3 review: the default path deliberately never refused, leaving the SSRF
    # denylist "to the callers that own it" — safe while every url here was a
    # hardcoded vendor host, a hole once `chat_base_url` made one tenant-writable.
    # A caller that owns a tenant-writable url opts in with `tenant_supplied: true`.
    test "a TENANT-SUPPLIED denylisted host is REFUSED even unmarked", %{scope: scope} do
      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "http://169.254.169.254/v1/chat/completions", :inference,
                 tenant_supplied: true
               )

      assert details.verdict == :denylisted
      assert details.remediation =~ "OPERATOR deployment allowlist"
    end

    test "a TENANT-SUPPLIED host the OPERATOR allowlisted is still allowed", %{scope: scope} do
      with_allowlist(["127.0.0.1"], fn ->
        assert {:ok, pinned} =
                 Policy.check(scope, "http://127.0.0.1:11434/v1/chat/completions", :inference,
                   tenant_supplied: true
                 )

        assert pinned.ip == {127, 0, 0, 1}
      end)
    end

    test "a TENANT-SUPPLIED PUBLIC host acquires no new failure mode", %{scope: scope} do
      assert {:ok, _} =
               Policy.check(scope, "https://api.openai.com/v1/chat/completions", :inference,
                 tenant_supplied: true
               )
    end

    # US-41.3 review: the residual half of the SSRF finding. `{:ok, :unpinned}` keeps
    # Req's default redirect-FOLLOWING and no IP pin, and the default path fell
    # through to it for ANY non-denylist failure — an unresolvable host, a resolve
    # slower than the 3s timeout, a classifier raise/exit/throw. For a
    # TENANT-CONTROLLED host that is an attacker-INFLUENCED condition: make the first
    # resolution fail and the connect-time resolution can land on 127.0.0.1 /
    # 169.254.169.254 / a Fly 6PN peer, redirects followed on top. It must fail
    # CLOSED — and as the TRANSIENT `:egress_unavailable` (workers snooze), because a
    # resolve failure is a blip, not the permanent configuration state
    # `:egress_blocked` denotes.
    test "a TENANT-SUPPLIED unresolvable host FAILS CLOSED instead of going unpinned",
         %{tenant: tenant, scope: scope} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> {:error, :nxdomain} end)
      url = "https://tenant-chosen.example.com/v1"

      # The same url on the VENDOR path still degrades to unpinned — the fix must not
      # hand default (non-tenant-supplied) traffic a brand-new failure mode.
      assert {:ok, :unpinned} = Policy.check(scope, url, :inference)
      PinCache.invalidate_tenant(tenant.id)

      assert {:error, :egress_unavailable, details} =
               Policy.check(scope, url, :inference, tenant_supplied: true)

      assert details.verdict == :unclassifiable
      assert details.remediation =~ "refused"
    end

    test "a TENANT-SUPPLIED host whose classifier RAISES fails closed too", %{scope: scope} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> raise "classifier exploded" end)

      assert {:error, :egress_unavailable, _details} =
               Policy.check(scope, "https://tenant-chosen.example.com/v1", :inference,
                 tenant_supplied: true
               )
    end
  end

  # THE pair the purpose scoping exists for. A deployment whose model endpoint is
  # network-local must keep working unchanged, while the SAME host stops being an
  # acceptable destination for a tenant-authored webhook. Both halves are asserted
  # on ONE host under ONE allowlist so neither can be satisfied by a change that
  # simply refuses (or admits) everything.
  describe "an operator carve-out answers for the purpose it names" do
    test "the UNCHANGED inference deployment still resolves, and webhook does not",
         %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      # The documented, pre-existing form of the entry — a bare host, untouched by
      # an operator upgrading past this change.
      with_allowlist(["127.0.0.1"], fn ->
        assert {:ok, pinned} =
                 Policy.check(scope, "http://127.0.0.1:11434/v1/embeddings", :inference)

        assert pinned.ip == {127, 0, 0, 1}

        assert {:error, :egress_blocked, details} =
                 Policy.check(scope, "http://127.0.0.1:11434/hooks", :webhook,
                   tenant_supplied: true
                 )

        # `:denylisted`, NOT `:non_local`: an ungranted carve-out must fall back to
        # what the ADDRESS is, or an unmarked scope would pin and connect to it.
        assert details.verdict == :denylisted
      end)
    end

    test "naming webhook grants it WITHOUT taking inference away", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      with_allowlist(["127.0.0.1@inference+webhook"], fn ->
        assert {:ok, _} = Policy.check(scope, "http://127.0.0.1:11434/v1/embeddings", :inference)

        assert {:ok, _} =
                 Policy.check(scope, "http://127.0.0.1:9000/hooks", :webhook,
                   tenant_supplied: true
                 )
      end)
    end

    test "a port-bound entry keeps inference working on the port it names",
         %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      with_allowlist(["127.0.0.1:11434"], fn ->
        assert {:ok, _} = Policy.check(scope, "http://127.0.0.1:11434/v1/embeddings", :inference)

        assert {:error, :egress_blocked, _} =
                 Policy.check(scope, "http://127.0.0.1:8080/v1/embeddings", :inference)
      end)
    end
  end

  describe "local_only refusal (AC-41.4.3, TC-41.4.1)" do
    test "a vendor endpoint is refused BEFORE any request", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "https://api.openai.com/v1/embeddings", :inference)

      assert details.host == "api.openai.com"
      assert details.verdict == :non_local
      assert details.remediation =~ "not local for this scope"
    end

    test "an allowlisted loopback endpoint IS allowed", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      with_allowlist(["127.0.0.1"], fn ->
        assert {:ok, pinned} =
                 Policy.check(scope, "http://127.0.0.1:11434/v1/embeddings", :inference)

        assert pinned.host == "127.0.0.1"
        assert pinned.ip == {127, 0, 0, 1}
      end)
    end

    test "a private-range host NOT in the allowlist is denylisted, with operator remediation",
         %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "http://10.0.0.5:11434/v1/embeddings", :inference)

      assert details.verdict == :denylisted
      assert details.remediation =~ "OPERATOR deployment allowlist"
    end

    test "an unclassifiable endpoint FAILS CLOSED (TC-41.4.4)", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)
      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> {:error, :nxdomain} end)

      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "https://who-knows.example.com/v1/embeddings", :inference)

      assert details.verdict == :unclassifiable
      assert details.remediation =~ "could not be classified as local"
    end

    test "a RAISING classifier fails closed, never admits (TC-41.4.4)", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)
      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> raise "classifier exploded" end)

      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "https://boom.example.com/v1/embeddings", :inference)

      assert details.verdict == :unclassifiable
    end

    test "a URL with no host is refused", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)
      assert {:error, :egress_blocked, _} = Policy.check(scope, "not-a-url", :inference)
    end
  end

  describe "tenant declarations change the VERDICT, never the denylist (AC-41.4.9)" do
    setup %{tenant: t} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "ollama.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      :ok = mark_local_only(t.id)
      :ok
    end

    test "a declared public host is allowed for its declared purpose", %{scope: scope} do
      assert {:ok, pinned} =
               Policy.check(scope, "https://ollama.example.com/v1/embeddings", :inference)

      assert pinned.ip == {203, 0, 113, 10}
    end

    test "the same host is REFUSED for an undeclared purpose (purpose scoping)", %{scope: scope} do
      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "https://ollama.example.com/hook", :webhook)

      assert details.verdict == :non_local
    end

    # REGRESSION (review): the cache stored a PURPOSE-DERIVED verdict keyed only on
    # (tenant, scope, host), so the FIRST purpose to touch a host fixed its verdict
    # for the whole TTL — classify under :webhook first and the legitimately
    # DECLARED inference endpoint was refused for up to 10 minutes. AC-41.4.5
    # constraint (2) makes purpose scoping a security invariant, so it must be
    # re-derived on every read, in EITHER order.
    test "the verdict is purpose-scoped in BOTH orders — a cached entry never fixes it",
         %{scope: scope} do
      # Undeclared purpose FIRST (this is the ordering the old cache got wrong).
      assert {:error, :egress_blocked, %{verdict: :non_local}} =
               Policy.check(scope, "https://ollama.example.com/hook", :webhook)

      # ... and the declared purpose is still honoured on the cached entry.
      assert {:ok, %{ip: {203, 0, 113, 10}}} =
               Policy.check(scope, "https://ollama.example.com/v1/embeddings", :inference)

      # ... and back again.
      assert {:error, :egress_blocked, %{verdict: :non_local}} =
               Policy.check(scope, "https://ollama.example.com/hook", :webhook)
    end

    test "an UNDECLARED public endpoint under the same marking is blocked", %{scope: scope} do
      assert {:error, :egress_blocked, _} =
               Policy.check(scope, "https://other.example.com/v1/embeddings", :inference)
    end

    test "posture labels it tenant-declared, NEVER network-local", %{tenant: t} do
      posture = Egress.posture(t.id, :agent)
      [declared] = posture.declared_endpoints
      assert declared.locality_label == Egress.tenant_declared_label()
      assert declared.locality_label =~ "unverified attestation"
    end
  end

  describe "invalidation is CLUSTER-WIDE, not node-local (AC-41.4.12)" do
    # REGRESSION (review): `invalidate_tenant/1` was a bare node-local
    # `:ets.match_delete/2`. loopctl CLUSTERS (DNSCluster is wired in the
    # supervision tree) and Erlang does not share ETS, so a revoked declaration kept
    # working on peer nodes for the rest of the 10-minute TTL — and, because the
    # scope's local_only MARKING is cached in the same table, ENABLING local_only on
    # node A left node B answering `local_only: false` for up to ten minutes: a
    # privacy control with a ten-minute activation hole, while the posture report
    # attested the tightened posture. The repo already ships this pattern twice
    # (`Llm.SettingsCache`, `Auth.ApiKeyCache`).
    test "an invalidation is broadcast to peer nodes over PubSub", %{tenant: t} do
      :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, "egress:pin_cache:invalidate")

      # The broadcast is issued BY the cache owner (so the originating node's own
      # subscriber is excluded), hence the round trip through the GenServer.
      :ok = PinCache.invalidate_tenant(t.id)

      # The topic is GLOBAL, so a CONCURRENT async test invalidating a different
      # tenant can land first. Asserting on the FIRST message received made this
      # test lose that race (two different tenant UUIDs). Drain until OUR tenant's
      # broadcast arrives instead.
      assert_invalidate_received(t.id)
    end

    test "the owner busts its node-local table when a PEER broadcasts", %{tenant: t, scope: scope} do
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{93, 184, 216, 34}]} end)
      :ok = mark_local_only(t.id)

      assert {:error, :egress_blocked, _} =
               Policy.check(scope, "https://api.openai.com/v1/embeddings", :inference)

      assert {:ok, _} = PinCache.fetch(t.id, Scope.key(scope), "api.openai.com")

      # Simulate the message a peer node's broadcast delivers to this node's owner.
      send(PinCache, {:invalidate, t.id})
      # Round-trip a call through the owner to be sure the cast/info was processed.
      _ = :sys.get_state(PinCache)

      assert PinCache.fetch(t.id, Scope.key(scope), "api.openai.com") == :miss
    end
  end

  describe "fail-closed is SCOPED, not universal (AC-41.4.12)" do
    # REGRESSION (review): `check/3` wrapped the WHOLE decision — including the
    # marking lookup — in the fail-closed rescue, so a DBConnection blip on the
    # 3-connection AdminRepo pool returned the PERMANENT `:egress_blocked` for a
    # scope with NO marking at all, and every worker maps that to {:cancel, _}.
    # Seconds of pool pressure permanently cancelled embedding/extraction work for
    # DEFAULT tenants. The marking is now resolved OUTSIDE the rescue, and its own
    # failure is the TRANSIENT `:egress_unavailable`.
    test "a marking-lookup failure is TRANSIENT :egress_unavailable, never :egress_blocked" do
      # A scope whose tenant_id is not a UUID makes the marking query raise exactly
      # the way a pool/connection failure does: inside `marking/1`, before any
      # classification.
      scope = %Scope{tenant_id: "not-a-uuid", project_id: nil}

      assert {:error, :egress_unavailable, details} =
               Policy.check(scope, "https://api.openai.com/v1/embeddings", :inference)

      assert details.verdict == :marking_unavailable
      assert details.remediation =~ "NOT a privacy refusal"
    end

    test "the transient refusal SNOOZES an Oban worker instead of cancelling it" do
      assert {:snooze, seconds} = Egress.oban_result({:egress_unavailable, %{}})
      assert is_integer(seconds) and seconds > 0

      # ... and `:pin_stale` too: a DHCP lease change must not permanently drop
      # every in-flight job (nothing re-enqueues a cancelled job after the re-pin).
      assert {:snooze, _} = Egress.oban_result({:pin_stale, %{}})

      # Only the PERMANENT refusal cancels — and its reason NAMES scope + endpoint.
      assert {:cancel, reason} =
               Egress.oban_result(
                 {:egress_blocked,
                  %{scope: "tenant:x", host: "api.openai.com", verdict: :non_local}}
               )

      assert reason =~ "tenant:x"
      assert reason =~ "api.openai.com"
    end
  end

  describe "pin cache (AC-41.4.12, TC-41.4.14)" do
    setup %{tenant: t} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "ollama.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      :ok = mark_local_only(t.id)
      :ok
    end

    test "tenant A's declaration never makes the host local for tenant B", %{tenant: a, scope: sa} do
      b = fixture(:tenant)
      on_exit(fn -> PinCache.invalidate_tenant(b.id) end)
      :ok = mark_local_only(b.id)
      sb = Scope.new(b.id)

      assert {:ok, _pinned} = Policy.check(sa, "https://ollama.example.com/x", :inference)
      # The cache key is (tenant_id, scope, host) — never host alone.
      assert {:error, :egress_blocked, _} =
               Policy.check(sb, "https://ollama.example.com/x", :inference)

      assert a.id != b.id
    end

    test "a revoke invalidates IMMEDIATELY — no TTL grace", %{tenant: t, scope: scope} do
      assert {:ok, _} = Policy.check(scope, "https://ollama.example.com/x", :inference)
      assert {:ok, _entry} = PinCache.fetch(t.id, Scope.key(scope), "ollama.example.com")

      {:ok, :revoked} = Egress.revoke_trusted_endpoint(t.id, "ollama.example.com")

      assert PinCache.fetch(t.id, Scope.key(scope), "ollama.example.com") == :miss

      assert {:error, :egress_blocked, _} =
               Policy.check(scope, "https://ollama.example.com/x", :inference)
    end

    test "an IP change surfaces a DISTINCT :pin_stale, and a re-pin recovers it without a :user write",
         %{tenant: t, scope: scope} do
      assert {:ok, _} = Policy.check(scope, "https://ollama.example.com/x", :inference)

      # The box got a new lease. The supervised refresher notices BEFORE expiry.
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "ollama.example.com" -> {:ok, [{203, 0, 113, 99}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      :ok = PinCache.mark_due(t.id, Scope.key(scope), "ollama.example.com")
      assert PinCache.refresh_now(t.id) >= 1

      assert {:error, :pin_stale, details} =
               Policy.check(scope, "https://ollama.example.com/x", :inference)

      # NEVER conflated with :egress_blocked, and remediation is a re-pin.
      assert details.remediation =~ "Re-pin"
      assert details.remediation =~ "no role :user write"

      assert {:ok, %{verdict: :tenant_declared}} =
               Policy.repin(scope, "ollama.example.com", :inference)

      assert {:ok, pinned} = Policy.check(scope, "https://ollama.example.com/x", :inference)
      assert pinned.ip == {203, 0, 113, 99}
    end

    # REGRESSION (review): the refresher revalidated DENYLISTED entries too. A
    # private-range host can never revalidate (`reresolve/1` -> {:error, :blocked_ip}),
    # so after the first jittered refresh a permanently unreachable endpoint became
    # `pin_stale` — reported as a TRANSIENT error with a re-pin remediation that can
    # never help, mislabelled `verdict: :tenant_declared` for a host never declared,
    # and (because Provider does not record a blocked decision on :pin_stale) the
    # AC-41.4.6 blocked counter/audit trail SILENTLY STOPPED for a still-blocked
    # tenant.
    test "a denylisted entry stays :egress_blocked with its REAL verdict across refreshes",
         %{tenant: t, scope: scope} do
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "private.example.com" -> {:ok, [{10, 0, 0, 5}]}
        "ollama.example.com" -> {:ok, [{203, 0, 113, 10}]}
        _ -> {:ok, [{93, 184, 216, 34}]}
      end)

      assert {:error, :egress_blocked, %{verdict: :denylisted}} =
               Policy.check(scope, "https://private.example.com/x", :inference)

      # Force a refresh pass over the whole table.
      :ok = PinCache.mark_due(t.id, Scope.key(scope), "private.example.com")
      PinCache.refresh_now(t.id)

      {:ok, entry} = PinCache.fetch(t.id, Scope.key(scope), "private.example.com")
      refute entry.pin_stale

      assert {:error, :egress_blocked, %{verdict: :denylisted}} =
               Policy.check(scope, "https://private.example.com/x", :inference)
    end

    test "the refresher re-pins BEFORE expiry, so TTL rollover is not a fleet-wide refusal",
         %{tenant: t, scope: scope} do
      assert {:ok, _} = Policy.check(scope, "https://ollama.example.com/x", :inference)
      {:ok, entry} = PinCache.fetch(t.id, Scope.key(scope), "ollama.example.com")

      # The refresh point is strictly BEFORE the hard expiry — that gap is the
      # whole point of a supervised refresher.
      assert entry.refresh_at < entry.expires_at

      :ok = PinCache.mark_due(t.id, Scope.key(scope), "ollama.example.com")
      assert PinCache.refresh_now(t.id) >= 1

      {:ok, refreshed} = PinCache.fetch(t.id, Scope.key(scope), "ollama.example.com")
      refute refreshed.pin_stale
      assert {:ok, _} = Policy.check(scope, "https://ollama.example.com/x", :inference)
    end

    test "a default tenant on vendor endpoints is unaffected: never refused, pin cached" do
      default = fixture(:tenant)
      on_exit(fn -> PinCache.invalidate_tenant(default.id) end)
      scope = Scope.new(default.id)

      # Allowed (never refused), and pinned from the SAME cached entry the
      # local_only path uses — not a fresh DNS resolve per request.
      assert {:ok, %{host: "api.openai.com"}} =
               Policy.check(scope, "https://api.openai.com/v1/embeddings", :inference)

      assert {:ok, %{base_verdict: :public}} =
               PinCache.fetch(default.id, Scope.key(scope), "api.openai.com")
    end

    test "the cached path does no DNS resolution (hot-path cost is one ETS read)",
         %{scope: scope} do
      assert {:ok, _} = Policy.check(scope, "https://ollama.example.com/x", :inference)

      # Any further resolution would blow up — the cached path must not resolve.
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> raise "hot path resolved DNS" end)

      {elapsed_us, result} =
        :timer.tc(fn -> Policy.check(scope, "https://ollama.example.com/x", :inference) end)

      assert {:ok, _pinned} = result
      # Documented timing assertion: an ETS read, generously bounded.
      assert elapsed_us < 5_000
    end
  end

  describe "the deployment allowlist is the ONLY carve-out (AC-41.4.9)" do
    test "an allowlisted CIDR reaches a private host", %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      with_allowlist(["10.1.0.0/16"], fn ->
        assert {:ok, pinned} = Policy.check(scope, "http://10.1.2.3:11434/v1", :inference)
        assert pinned.ip == {10, 1, 2, 3}
      end)
    end

    test "a tenant CANNOT reach a private host via a public hostname that resolves there",
         %{tenant: t, scope: scope} do
      :ok = mark_local_only(t.id)

      stub(Loopctl.MockDnsResolver, :resolve, fn "sneaky.example.com" ->
        {:ok, [{10, 0, 0, 5}]}
      end)

      # Even declaring it is impossible (see EgressTest); reaching it is refused too.
      assert {:error, :egress_blocked, details} =
               Policy.check(scope, "https://sneaky.example.com/v1", :inference)

      assert details.verdict == :denylisted
    end

    # REGRESSION (review): revalidation re-puts a REFRESHED `:ips` but carries the
    # ORIGINAL `:ungranted_base` forward. A host allowlisted BY NAME whose DNS
    # moved from a public to a PRIVATE answer therefore kept `:public`, fell back
    # to `:non_local` for a purpose the carve-out does not grant, passed the
    # denylist gate — and was pinned and connected to on the private address.
    test "a name-allowlisted host that MOVES to a private address is refused, not pinned",
         %{tenant: t, scope: scope} do
      with_allowlist(["vendor.example.com@inference"], fn ->
        stub(Loopctl.MockDnsResolver, :resolve, fn
          "vendor.example.com" -> {:ok, [{203, 0, 113, 10}]}
          _ -> {:ok, [{93, 184, 216, 34}]}
        end)

        assert {:ok, _} = Policy.check(scope, "https://vendor.example.com/v1", :inference)

        # The name still resolves — to the operator's private network now.
        stub(Loopctl.MockDnsResolver, :resolve, fn
          "vendor.example.com" -> {:ok, [{10, 0, 0, 5}]}
          _ -> {:ok, [{93, 184, 216, 34}]}
        end)

        :ok = PinCache.mark_due(t.id, Scope.key(scope), "vendor.example.com")
        assert PinCache.refresh_now(t.id) >= 1

        # `webhook` is a purpose the carve-out does not name, so the host falls
        # back to what its CURRENT addresses make it: denylisted.
        assert {:error, :egress_blocked, details} =
                 Policy.check(scope, "https://vendor.example.com/hook", :webhook,
                   tenant_supplied: true
                 )

        assert details.verdict == :denylisted
        assert details.purpose == :webhook
        assert details.remediation =~ "'webhook' purpose"
      end)
    end

    # REGRESSION (review): `repin/3` classified with the `:any` port, which by
    # design matches only a PORTLESS entry — so a re-pin reported `denylisted` for
    # a host that inference calls (which carry a port) reach without a problem,
    # and sent the agent to a remediation only the operator could act on.
    test "a re-pin reports the verdict for the port the SCOPE actually uses",
         %{tenant: t, scope: scope} do
      fixture(:tenant_llm_settings,
        tenant_id: t.id,
        chat_provider: "openai_compatible",
        chat_base_url: "http://ollama.internal:11434/v1",
        extraction_model: "llama3.1"
      )

      with_allowlist(["ollama.internal:11434"], fn ->
        stub(Loopctl.MockDnsResolver, :resolve, fn
          "ollama.internal" -> {:ok, [{10, 0, 0, 5}]}
          _ -> {:ok, [{93, 184, 216, 34}]}
        end)

        assert {:ok, %{verdict: :network_local}} =
                 Policy.repin(scope, "ollama.internal", :inference)
      end)
    end

    # REGRESSION (review): the port came from the FIRST resolved endpoint on the
    # host (always `:embedding`), so a scope whose embedding and chat endpoints
    # share a host on different ports re-pinned against the wrong one — answering
    # `network_local` while the call the agent was recovering stays refused.
    test "a re-pin over a host reached on two ports reports the LEAST permissive",
         %{tenant: t, scope: scope} do
      # The embedding endpoint is `https://api.openai.com/v1` (port 443) under
      # test config, so pointing chat at the same host on another port is what
      # makes the two resolved endpoints collide.
      fixture(:tenant_llm_settings,
        tenant_id: t.id,
        chat_provider: "openai_compatible",
        chat_base_url: "http://api.openai.com:8080/v1",
        extraction_model: "llama3.1"
      )

      with_allowlist(["api.openai.com:443"], fn ->
        stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{10, 0, 0, 5}]} end)

        # 443 is carved out; 8080 — the port the chat call actually uses — is not.
        assert {:ok, %{verdict: :denylisted}} =
                 Policy.repin(scope, "api.openai.com", :inference)
      end)
    end

    # REGRESSION (review): a host the tenant only DECLARED is not a resolved
    # endpoint, so the port fell back to `:any`, which by design matches no
    # port-bound entry — the same wrong verdict the port fix was written to remove.
    test "a re-pin over a non-endpoint host uses the port the carve-out states",
         %{scope: scope} do
      with_allowlist(["declared.internal:11434@inference"], fn ->
        stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{10, 0, 0, 7}]} end)

        assert {:ok, %{verdict: :network_local}} =
                 Policy.repin(scope, "declared.internal", :inference)
      end)
    end
  end

  # The allowlist is DEPLOYMENT configuration, so a test that exercises an
  # operator carve-out must set it. It is set PROCESS-LOCALLY via the config-based
  # test source (never `Application.put_env` — forbidden, and a global race under
  # `async: true`). There is no API path that writes it at any role (see
  # EgressControllerTest, TC-41.4.7).
  defp with_allowlist(entries, fun) do
    AllowlistSource.put(entries)

    try do
      fun.()
    after
      AllowlistSource.clear()
    end
  end

  # `"egress:pin_cache:invalidate"` is a GLOBAL topic, so a concurrent async test
  # invalidating a DIFFERENT tenant can be delivered first. Drain until ours
  # arrives rather than asserting on whichever message happens to be first.
  defp assert_invalidate_received(tenant_id) do
    receive do
      {:invalidate, ^tenant_id} -> :ok
      {:invalidate, _other_tenant} -> assert_invalidate_received(tenant_id)
    after
      1_000 -> flunk("no {:invalidate, #{tenant_id}} broadcast received")
    end
  end
end
