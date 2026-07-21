defmodule LoopctlWeb.CustodyClaimControllerTest do
  @moduledoc """
  US-41.7 web surface (AC-41.7.5): the agent-readable custody claim and the
  public inclusion-proof path (AC-41.7.4).
  """

  use LoopctlWeb.ConnCase, async: true

  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Verifier
  alias Loopctl.Custody
  alias Loopctl.Custody.PostureEntry
  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Knowledge
  alias Loopctl.Test.AllowlistSource

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)

    on_exit(fn ->
      PinCache.invalidate_tenant(tenant.id)
      AllowlistSource.clear()
    end)

    {raw_agent, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    {:ok, tenant: tenant, agent_key: raw_agent}
  end

  defp auth(conn, raw), do: put_req_header(conn, "authorization", "Bearer #{raw}")

  defp local_article(tenant_id) do
    AllowlistSource.put(["api.openai.com", "api.anthropic.com"])
    {:ok, _} = Egress.enable_local_only(tenant_id, nil, acknowledge: true)
    PinCache.invalidate_tenant(tenant_id)

    {:ok, article} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        Knowledge.create_article(tenant_id, build(:article, %{status: :draft}))
      end)

    Oban.drain_queue(queue: :audit, with_scheduled: true)
    article
  end

  describe "GET /custody/claims/:subject_type/:subject_id (AC-41.7.5)" do
    test "an AGENT key can read the claim — verify-after-harvest needs no human", %{
      conn: conn,
      tenant: t,
      agent_key: key
    } do
      article = local_article(t.id)

      body =
        conn
        |> auth(key)
        |> get(~p"/api/v1/custody/claims/article/#{article.id}")
        |> json_response(200)

      claim = body["data"]
      assert claim["claim_state"] == "claim_recorded"
      assert claim["completeness"] == "complete"
      assert claim["third_party_egress_on_covered_paths"] == false
      assert claim["coverage"]["covered_paths"] == ["provider_calls"]
      assert claim["attestation_scope"] =~ "endpoints loopctl called"
    end

    test "the payload never carries UNQUALIFIED zero-egress wording (AC-41.7.6)", %{
      conn: conn,
      tenant: t,
      agent_key: key
    } do
      article = local_article(t.id)

      raw =
        conn
        |> auth(key)
        |> get(~p"/api/v1/custody/claims/article/#{article.id}")
        |> response(200)

      refute raw =~ "zero third-party egress"
      refute raw =~ "never seen by a third party"
      assert raw =~ "covered egress paths"
    end

    test "an unrecorded row reads as ABSENT, not as satisfied", %{
      conn: conn,
      agent_key: key
    } do
      body =
        conn
        |> auth(key)
        |> get(~p"/api/v1/custody/claims/article/#{Ecto.UUID.generate()}")
        |> json_response(200)

      assert body["data"]["claim_state"] == "no_claim_recorded"
      refute Map.has_key?(body["data"], "posture")
    end

    test "an unknown subject type is a 400, not a silently empty claim", %{
      conn: conn,
      agent_key: key
    } do
      body =
        conn
        |> auth(key)
        |> get(~p"/api/v1/custody/claims/story/#{Ecto.UUID.generate()}")
        |> json_response(400)

      assert body["error"]["code"] == "invalid_subject_type"
    end

    test "an unauthenticated caller is rejected", %{conn: conn} do
      conn
      |> get(~p"/api/v1/custody/claims/article/#{Ecto.UUID.generate()}")
      |> json_response(401)
    end

    test "tenant B cannot read tenant A's claim (TC-41.7.9)", %{conn: conn, tenant: a} do
      article = local_article(a.id)

      b = fixture(:tenant)
      {raw_b, _} = fixture(:api_key, %{tenant_id: b.id, role: :agent})

      body =
        conn
        |> auth(raw_b)
        |> get(~p"/api/v1/custody/claims/article/#{article.id}")
        |> json_response(200)

      assert body["data"]["claim_state"] == "no_claim_recorded"
      assert body["data"]["entries"] == []
    end
  end

  describe "GET /custody/failures" do
    test "a dropped append is SURFACED rather than silently absent", %{
      conn: conn,
      tenant: t,
      agent_key: key
    } do
      article = local_article(t.id)
      [entry] = Custody.list_entries(t.id, "article", article.id)
      batch = Custody.batch_id(4242)

      import Ecto.Query

      from(e in PostureEntry, where: e.id == ^entry.id)
      |> AdminRepo.update_all(set: [state: "pending", batch_id: batch])

      Custody.mark_batch_failed(t.id, batch, "chain append exhausted retries")

      body =
        conn
        |> auth(key)
        |> get(~p"/api/v1/custody/failures")
        |> json_response(200)

      assert body["meta"]["count"] == 1
      assert hd(body["data"])["failure_reason"] =~ "exhausted retries"
    end
  end

  describe "GET /audit/sth/:tenant_id/inclusion/:position (AC-41.7.4)" do
    setup %{tenant: tenant} do
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
      Loopctl.TenantKeys.init_cache()
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: pub)
        |> AdminRepo.update!()

      {:ok, tenant: tenant, public_key: pub}
    end

    test "the published proof verifies against the published STH — no new signing scheme",
         %{conn: conn, tenant: t, public_key: pub} do
      article = local_article(t.id)
      [entry] = Custody.list_entries(t.id, "article", article.id)
      {:ok, _sth} = AuditChain.sign_and_store_tree_head(t.id)

      body =
        conn
        |> get(~p"/api/v1/audit/sth/#{t.id}/inclusion/#{entry.chain_position}")
        |> json_response(200)

      data = body["data"]
      assert data["leaf_index"] == entry.chain_position

      leaf = decode(data["leaf_hash"])
      root = decode(data["sth"]["merkle_root"])

      path =
        Enum.map(data["audit_path"], fn %{"position" => side, "hash" => hash} ->
          %{position: String.to_existing_atom(side), hash: decode(hash)}
        end)

      assert {:ok, true} = Verifier.verify_inclusion(leaf, path, root)

      sth = %{
        tenant_id: t.id,
        chain_position: data["sth"]["chain_position"],
        merkle_root: root,
        signed_at: elem(DateTime.from_iso8601(data["sth"]["signed_at"]), 1),
        signature: decode(data["sth"]["signature"])
      }

      assert {:ok, true} = Verifier.verify_sth(sth, pub)
    end

    test "an entry with no covering STH yet is a distinct 409, not a 404", %{
      conn: conn,
      tenant: t
    } do
      _article = local_article(t.id)

      body =
        conn
        |> get(~p"/api/v1/audit/sth/#{t.id}/inclusion/0")
        |> json_response(409)

      assert body["error"]["code"] == "not_yet_included"
    end

    test "an unknown position is a 404", %{conn: conn, tenant: t} do
      conn
      |> get(~p"/api/v1/audit/sth/#{t.id}/inclusion/99999")
      |> json_response(404)
    end
  end

  defp decode(value), do: Base.url_decode64!(value, padding: false)
end
