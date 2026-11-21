defmodule Loopctl.HoldersTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Holders
  alias Loopctl.Holders.Holder

  setup :verify_on_exit!

  defp attrs(session_id, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "interactive",
        "session_id" => session_id,
        "host" => "minis",
        "worktree" => "/w"
      },
      extra
    )
  end

  setup do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id})
    %{tenant: tenant, agent: agent}
  end

  describe "register/4" do
    test "creates a live holder and a credential bound to it", %{tenant: tenant, agent: agent} do
      assert {:ok, %{holder: holder, raw_key: raw, api_key: key, outcome: :created}} =
               Holders.register(tenant.id, agent.id, attrs("s1"))

      assert holder.kind == :interactive
      assert holder.agent_id == agent.id
      assert is_nil(holder.ended_at)
      assert key.holder_id == holder.id
      assert key.agent_id == agent.id
      assert key.role == :agent

      assert DateTime.compare(
               key.expires_at,
               DateTime.add(holder.lease_until, Holders.heartbeat_seconds(), :second)
             ) == :eq

      assert {:ok, %ApiKey{id: id}} = Auth.verify_api_key(raw)
      assert id == key.id
    end

    test "a retry for a live session reuses the holder and rotates its credential",
         %{tenant: tenant, agent: agent} do
      {:ok, first} = Holders.register(tenant.id, agent.id, attrs("s1"))
      {:ok, second} = Holders.register(tenant.id, agent.id, attrs("s1"))

      assert second.outcome == :rotated
      assert second.holder.id == first.holder.id
      refute second.raw_key == first.raw_key
      assert {:error, :unauthorized} = Auth.verify_api_key(first.raw_key)
      assert {:ok, _} = Auth.verify_api_key(second.raw_key)

      assert AdminRepo.aggregate(
               from(h in Holder, where: h.tenant_id == ^tenant.id and is_nil(h.ended_at)),
               :count
             ) == 1
    end

    test "after end a new holder may be registered for the same session",
         %{tenant: tenant, agent: agent} do
      {:ok, first} = Holders.register(tenant.id, agent.id, attrs("s1"))
      {:ok, _ended} = Holders.end_holder(tenant.id, first.api_key, first.holder.id)

      assert {:ok, %{outcome: :created, holder: second}} =
               Holders.register(tenant.id, agent.id, attrs("s1"))

      refute second.id == first.holder.id
    end

    test "refuses runner_session as a self-registered kind", %{tenant: tenant, agent: agent} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Holders.register(tenant.id, agent.id, attrs("s1", %{"kind" => "runner_session"}))

      assert %{kind: [_]} = errors_on(cs)
    end

    test "requires session_id and host", %{tenant: tenant, agent: agent} do
      assert {:error, cs} = Holders.register(tenant.id, agent.id, %{"kind" => "interactive"})
      assert %{session_id: [_], host: [_]} = errors_on(cs)
    end

    test "writes one audit row per register and per rotate", %{tenant: tenant, agent: agent} do
      {:ok, %{holder: holder}} = Holders.register(tenant.id, agent.id, attrs("s1"))
      {:ok, _} = Holders.register(tenant.id, agent.id, attrs("s1"))

      actions =
        from(a in Loopctl.Audit.AuditLog,
          where: a.tenant_id == ^tenant.id and a.entity_id == ^holder.id,
          order_by: a.inserted_at,
          select: a.action
        )
        |> AdminRepo.all()

      assert actions == ["registered", "credential_rotated"]
    end
  end

  describe "the api_keys indexes" do
    test "two holders of one agent each hold a live :agent key beside its plain one",
         %{tenant: tenant, agent: agent} do
      {_raw, _plain} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      {:ok, h1} = Holders.register(tenant.id, agent.id, attrs("s1"))
      {:ok, h2} = Holders.register(tenant.id, agent.id, attrs("s2"))

      assert {:ok, _} = Auth.verify_api_key(h1.raw_key)
      assert {:ok, _} = Auth.verify_api_key(h2.raw_key)

      assert {:error, cs} =
               Auth.generate_api_key(%{
                 tenant_id: tenant.id,
                 name: "dup",
                 role: :agent,
                 agent_id: agent.id
               })

      assert %{tenant_id: ["agent already has an active key with this role"]} = errors_on(cs)

      assert {:error, cs} =
               Auth.generate_api_key(
                 %{tenant_id: tenant.id, name: "dup", role: :agent, agent_id: agent.id},
                 holder_id: h1.holder.id
               )

      assert %{holder_id: ["holder already has a live credential"]} = errors_on(cs)
    end
  end

  describe "heartbeat/4" do
    test "renews the lease and the credential's expiry", %{tenant: tenant, agent: agent} do
      t0 = ~U[2026-11-20 10:00:00.000000Z]
      {:ok, reg} = Holders.register(tenant.id, agent.id, attrs("s1"), now: t0)
      t1 = DateTime.add(t0, 30, :second)

      assert {:ok, holder} = Holders.heartbeat(tenant.id, reg.api_key, reg.holder.id, now: t1)
      assert holder.last_seen_at == t1
      assert holder.lease_until == DateTime.add(t1, Holders.lease_seconds(), :second)

      key = AdminRepo.get!(ApiKey, reg.api_key.id)

      assert DateTime.compare(
               key.expires_at,
               DateTime.add(holder.lease_until, Holders.heartbeat_seconds(), :second)
             ) == :eq
    end

    test "another holder's credential gets :not_found", %{tenant: tenant, agent: agent} do
      {:ok, h1} = Holders.register(tenant.id, agent.id, attrs("s1"))
      {:ok, h2} = Holders.register(tenant.id, agent.id, attrs("s2"))

      assert {:error, :not_found} = Holders.heartbeat(tenant.id, h2.api_key, h1.holder.id)
    end

    test "an ended holder is :holder_ended", %{tenant: tenant, agent: agent} do
      {:ok, reg} = Holders.register(tenant.id, agent.id, attrs("s1"))
      {:ok, _} = Holders.end_holder(tenant.id, reg.api_key, reg.holder.id)

      assert {:error, :holder_ended} = Holders.heartbeat(tenant.id, reg.api_key, reg.holder.id)
    end
  end

  describe "end_holder/4" do
    test "ends the holder, revokes the credential, and a repeat writes nothing",
         %{tenant: tenant, agent: agent} do
      {:ok, reg} = Holders.register(tenant.id, agent.id, attrs("s1"))

      assert {:ok, ended} = Holders.end_holder(tenant.id, reg.api_key, reg.holder.id)
      assert ended.ended_reason == :ended
      assert %DateTime{} = ended.ended_at
      assert {:error, :unauthorized} = Auth.verify_api_key(reg.raw_key)

      count = fn ->
        AdminRepo.aggregate(
          from(a in Loopctl.Audit.AuditLog,
            where: a.entity_id == ^reg.holder.id and a.action == "ended"
          ),
          :count
        )
      end

      assert count.() == 1
      assert {:ok, again} = Holders.end_holder(tenant.id, reg.api_key, reg.holder.id)
      assert again.ended_at == ended.ended_at
      assert count.() == 1
    end
  end

  describe "tenant isolation" do
    test "tenant B cannot read or act on tenant A's holder", %{tenant: tenant, agent: agent} do
      {:ok, reg} = Holders.register(tenant.id, agent.id, attrs("s1"))
      other = fixture(:tenant)

      assert {:error, :not_found} = Holders.get_holder(other.id, reg.holder.id)
      assert {:error, :not_found} = Holders.heartbeat(other.id, reg.api_key, reg.holder.id)
      assert {:error, :not_found} = Holders.end_holder(other.id, reg.api_key, reg.holder.id)
      assert {:ok, _} = Holders.get_holder(tenant.id, reg.holder.id)
    end
  end
end
