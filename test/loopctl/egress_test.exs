defmodule Loopctl.EgressTest do
  @moduledoc """
  Context tests for US-41.4: scope markings (AC-41.4.1/.2), tenant-declared
  trusted endpoints (AC-41.4.5), aggregated blocked decisions (AC-41.4.6) and
  tenant isolation (AC-41.4.11 / TC-41.4.13).
  """

  use Loopctl.DataCase, async: true

  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Scope

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)
    {:ok, tenant: tenant}
  end

  describe "scope precedence — most-restrictive-wins (AC-41.4.2, TC-41.4.8)" do
    setup %{tenant: tenant} do
      {:ok, project: fixture(:project, %{tenant_id: tenant.id})}
    end

    test "neither marked → not local_only", %{tenant: t, project: p} do
      refute Egress.effective_local_only?(Scope.new(t.id, p.id))
      refute Egress.effective_local_only?(Scope.new(t.id))
    end

    test "tenant marked → the project inherits it", %{tenant: t, project: p} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)

      assert Egress.effective_local_only?(Scope.new(t.id))
      assert Egress.effective_local_only?(Scope.new(t.id, p.id))
    end

    test "project marked → the tenant scope stays unmarked", %{tenant: t, project: p} do
      {:ok, _} = Egress.enable_local_only(t.id, p.id, acknowledge: true)

      assert Egress.effective_local_only?(Scope.new(t.id, p.id))
      refute Egress.effective_local_only?(Scope.new(t.id))
    end

    test "both marked → still blocked", %{tenant: t, project: p} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      {:ok, _} = Egress.enable_local_only(t.id, p.id, acknowledge: true)

      assert Egress.effective_local_only?(Scope.new(t.id, p.id))
    end

    test "a project can NEVER relax a tenant marking", %{tenant: t, project: p} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      # There is no "off" row: clearing the PROJECT marking leaves the tenant one.
      {:ok, :cleared} = Egress.clear_local_only(t.id, p.id)

      assert Egress.effective_local_only?(Scope.new(t.id, p.id))
    end

    test "a project-less row inherits the TENANT marking", %{tenant: t} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      # articles.project_id is nullable and memories have no project at all.
      assert Egress.effective_local_only?(Scope.new(t.id, nil))
    end

    test "a marking is invisible to another tenant (RLS, TC-41.4.13)", %{tenant: t} do
      other = fixture(:tenant)
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)

      assert Egress.effective_local_only?(Scope.new(t.id))
      refute Egress.effective_local_only?(Scope.new(other.id))
      assert Egress.list_markings(other.id) == []
    end
  end

  describe "enable pre-flight (AC-41.4.1, TC-41.4.6)" do
    test "refuses an unacknowledged enable that would block a vendor endpoint", %{tenant: t} do
      # Default config resolves the vendor endpoints — i.e. the state of every
      # existing tenant. Enabling without acknowledgement must NOT silently
      # produce a tenant-wide outage undoable only by a human :user key.
      assert {:error, {:would_block, blocked}} = Egress.enable_local_only(t.id, nil)
      assert [_ | _] = blocked
      # Each offending endpoint is NAMED.
      assert Enum.all?(blocked, &is_binary(&1.endpoint))
      assert Enum.any?(blocked, &(&1.endpoint =~ "openai.com"))
      # And nothing was written.
      refute Egress.effective_local_only?(Scope.new(t.id))
    end

    test "completes with the acknowledgement flag and REPORTS the blocked posture", %{tenant: t} do
      assert {:ok, %{blocked_endpoints: blocked}} =
               Egress.enable_local_only(t.id, nil, acknowledge: true)

      assert blocked != []
      assert Egress.effective_local_only?(Scope.new(t.id))
    end

    test "emits the alertable telemetry event naming actor, scope and blocked count", %{
      tenant: t
    } do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:loopctl, :egress, :local_only_enabled]])

      actor_id = Ecto.UUID.generate()
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true, actor_id: actor_id)

      assert_receive {[:loopctl, :egress, :local_only_enabled], ^ref, measurements, metadata}
      assert measurements.blocked_endpoint_count >= 1
      assert metadata.tenant_id == t.id
      assert metadata.actor_id == actor_id
      assert metadata.scope == "tenant:#{t.id}"
    end

    test "both transitions are audited", %{tenant: t} do
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      {:ok, :cleared} = Egress.clear_local_only(t.id, nil)

      actions =
        Loopctl.Audit.AuditLog
        |> Ecto.Query.where([a], a.tenant_id == ^t.id)
        |> Loopctl.AdminRepo.all()
        |> Enum.map(& &1.action)

      assert "egress.local_only_enabled" in actions
      assert "egress.local_only_cleared" in actions
    end
  end

  describe "tenant-declared trusted endpoints (AC-41.4.5, TC-41.4.2)" do
    test "a public hostname can be declared for a purpose", %{tenant: t} do
      assert {:ok, endpoint} =
               Egress.declare_trusted_endpoint(t.id, %{
                 "host" => "ollama.example.com",
                 "purposes" => ["inference"]
               })

      assert endpoint.host == "ollama.example.com"
      assert endpoint.purposes == ["inference"]
      assert Egress.declared_purposes(t.id, "ollama.example.com") == ["inference"]
    end

    test "a scheme-prefixed host is normalized to the authority", %{tenant: t} do
      assert {:ok, endpoint} =
               Egress.declare_trusted_endpoint(t.id, %{
                 "host" => "https://Ollama.Example.com/",
                 "purposes" => ["inference"]
               })

      assert endpoint.host == "ollama.example.com"
    end

    # CONSTRAINT 1: public addresses ONLY, rejected AT WRITE TIME. A tenant can
    # never carve the operator's network out of the SSRF denylist.
    for {label, literal} <- [
          {"link-local cloud metadata", "169.254.169.254"},
          {"RFC1918 10/8", "10.0.0.5"},
          {"loopback", "127.0.0.1"},
          {"CGNAT 100.64/10", "100.64.0.1"},
          {"Fly 6PN fdaa::/16", "[fdaa:0:1::5]"}
        ] do
      test "rejects a #{label} declaration at write time", %{tenant: t} do
        assert {:error, changeset} =
                 Egress.declare_trusted_endpoint(t.id, %{
                   "host" => unquote(literal),
                   "purposes" => ["inference"]
                 })

        assert %{host: [message]} = errors_on(changeset)
        assert message =~ "PUBLIC"
      end
    end

    test "rejects a PUBLIC hostname whose DNS resolves into a private range", %{tenant: t} do
      # The declaration path resolves the host: a public name answering 10.0.0.5
      # is refused at write time, not merely at connect time.
      stub(Loopctl.MockDnsResolver, :resolve, fn "sneaky.example.com" ->
        {:ok, [{10, 0, 0, 5}]}
      end)

      assert {:error, changeset} =
               Egress.declare_trusted_endpoint(t.id, %{
                 "host" => "sneaky.example.com",
                 "purposes" => ["inference"]
               })

      assert %{host: [_ | _]} = errors_on(changeset)
    end

    test "rejects vendor hosts (guardrail, not an integrity control)", %{tenant: t} do
      for vendor <- ["api.openai.com", "api.anthropic.com"] do
        assert {:error, changeset} =
                 Egress.declare_trusted_endpoint(t.id, %{
                   "host" => vendor,
                   "purposes" => ["inference"]
                 })

        assert %{host: [message]} = errors_on(changeset)
        assert message =~ "vendor"
      end
    end

    test "rejects an unknown or empty purpose", %{tenant: t} do
      assert {:error, cs} =
               Egress.declare_trusted_endpoint(t.id, %{
                 "host" => "ollama.example.com",
                 "purposes" => ["exfiltrate"]
               })

      assert %{purposes: [_ | _]} = errors_on(cs)

      assert {:error, cs2} =
               Egress.declare_trusted_endpoint(t.id, %{
                 "host" => "ollama.example.com",
                 "purposes" => []
               })

      assert %{purposes: [_ | _]} = errors_on(cs2)
    end

    test "a declaration is labelled an unverified attestation, never network-local", %{tenant: t} do
      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      posture = Egress.posture(t.id, :agent)
      [declared] = posture.declared_endpoints

      assert declared.locality_label ==
               "tenant-declared (unverified attestation), not network-local"

      refute declared.locality_label =~ ~r/^network-local$/
    end

    test "declarations are tenant-isolated", %{tenant: t} do
      other = fixture(:tenant)

      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      assert Egress.declared_purposes(t.id, "ollama.example.com") == ["inference"]
      assert Egress.declared_purposes(other.id, "ollama.example.com") == []
      assert Egress.list_trusted_endpoints(other.id) == []
    end

    test "revoking removes it and is not found twice", %{tenant: t} do
      {:ok, _} =
        Egress.declare_trusted_endpoint(t.id, %{
          "host" => "ollama.example.com",
          "purposes" => ["inference"]
        })

      assert {:ok, :revoked} = Egress.revoke_trusted_endpoint(t.id, "ollama.example.com")
      assert Egress.declared_purposes(t.id, "ollama.example.com") == []
      assert {:error, :not_found} = Egress.revoke_trusted_endpoint(t.id, "ollama.example.com")
    end
  end

  describe "blocked-decision aggregation (AC-41.4.6, TC-41.4.15)" do
    test "N blocked calls in one window produce ONE row with an accurate count", %{tenant: t} do
      scope = Scope.new(t.id)
      details = %{host: "api.openai.com", scope: Scope.key(scope), verdict: :non_local}

      ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :egress, :blocked]])

      for _ <- 1..25, do: :ok = Egress.record_blocked(scope, details)

      rows = Egress.list_blocked_decisions(t.id)
      assert length(rows) == 1
      assert hd(rows).occurrence_count == 25
      assert hd(rows).endpoint_host == "api.openai.com"
      assert hd(rows).reason == "non_local"

      # The exact per-call rate lives in telemetry, not in rows.
      for _ <- 1..25, do: assert_received({[:loopctl, :egress, :blocked], ^ref, %{count: 1}, _})
    end

    test "different endpoints/reasons get their own aggregated row", %{tenant: t} do
      scope = Scope.new(t.id)
      :ok = Egress.record_blocked(scope, %{host: "a.example.com", verdict: :non_local})
      :ok = Egress.record_blocked(scope, %{host: "b.example.com", verdict: :non_local})
      :ok = Egress.record_blocked(scope, %{host: "a.example.com", verdict: :denylisted})

      assert length(Egress.list_blocked_decisions(t.id)) == 3
    end

    test "blocked decisions are tenant-isolated", %{tenant: t} do
      other = fixture(:tenant)
      :ok = Egress.record_blocked(Scope.new(t.id), %{host: "a.example.com", verdict: :non_local})

      assert length(Egress.list_blocked_decisions(t.id)) == 1
      assert Egress.list_blocked_decisions(other.id) == []
    end
  end
end
