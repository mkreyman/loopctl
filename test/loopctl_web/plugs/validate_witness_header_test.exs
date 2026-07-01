defmodule LoopctlWeb.Plugs.ValidateWitnessHeaderTest do
  @moduledoc """
  US-26.5.2 + custody-01/02/03 hardening for the STH witness plug.

  Enforcement is disabled by default in test (config/test.exs), so these
  tests drive the plug directly with the `enforce: true` opt — no
  `Application.put_env` (forbidden by the repo test conventions).
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.SignedTreeHead
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Tenants
  alias LoopctlWeb.Plugs.ValidateWitnessHeader

  @enforce [enforce: true]

  # A valid 22-char base64url prefix that will NOT match a random signature.
  @other_prefix "ZZZZZZZZZZZZZZZZZZZZZZ"

  defp base_conn do
    Phoenix.ConnTest.build_conn()
  end

  defp with_api_key(conn, api_key) do
    Plug.Conn.assign(conn, :current_api_key, api_key)
  end

  # Inserts an STH at `position` with a known signature and returns the
  # server-side 22-char prefix the plug will compute from it.
  defp insert_sth(tenant_id, position) do
    signature = :crypto.strong_rand_bytes(64)

    %SignedTreeHead{tenant_id: tenant_id}
    |> SignedTreeHead.changeset(%{
      chain_position: position,
      merkle_root: :crypto.strong_rand_bytes(32),
      signed_at: DateTime.utc_now(),
      signature: signature
    })
    |> AdminRepo.insert!()

    Base.url_encode64(binary_part(signature, 0, 16), padding: false)
  end

  describe "enforcement gating" do
    test "passes through untouched when not enforcing" do
      conn = base_conn() |> ValidateWitnessHeader.call([])
      refute conn.halted
    end

    test "412 witness_header_missing when enforcing and no header" do
      api_key = %ApiKey{id: Ecto.UUID.generate(), tenant_id: Ecto.UUID.generate()}

      conn =
        base_conn()
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_missing"
    end
  end

  describe "FIX A — client-supplied divergence never halts the tenant" do
    test "mismatching prefix returns 409 witness_divergence with current-sth hint and NO halt" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      tenant_id = api_key.tenant_id
      _server_prefix = insert_sth(tenant_id, 5)

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "5:#{@other_prefix}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 409

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "witness_divergence"

      # Client is handed the server's current STH so it can resync.
      assert [hint] = get_resp_header(conn, "x-loopctl-current-sth")
      assert hint =~ ~r/\A\d+:[A-Za-z0-9_-]{22}\z/

      # The tenant's custody must NOT have been halted by raw client input.
      {:ok, tenant} = Tenants.get_tenant(tenant_id)
      refute Tenants.custody_halted?(tenant)
    end

    test "matching prefix passes through and does not halt" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      server_prefix = insert_sth(api_key.tenant_id, 7)

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "7:#{server_prefix}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      refute conn.halted
      assert is_nil(conn.status)
    end
  end

  describe "FIX B — fixed-length prefix, empty/short cannot evade divergence" do
    test "empty prefix (\"5:\") is rejected 412 witness_header_malformed" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      _server_prefix = insert_sth(api_key.tenant_id, 5)

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "5:")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_malformed"

      # Crucially: an empty prefix must NOT be silently accepted as "matching".
      refute conn.status == 200
    end

    test "short prefix is rejected 412 witness_header_malformed" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      _server_prefix = insert_sth(api_key.tenant_id, 5)

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "5:abc")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_malformed"
    end

    test "over-length prefix is rejected 412 witness_header_malformed" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "5:#{String.duplicate("A", 23)}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_malformed"
    end

    test "non-base64url prefix of the right length is rejected 412" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})

      conn =
        base_conn()
        # 22 chars but '+' and '/' are standard-base64, not base64url.
        |> put_req_header("x-loopctl-last-known-sth", "5:AAAAAAAAAA++//AAAAAAAA")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_malformed"
    end
  end

  describe "FIX C — bootstrap grace is one-time per API key" do
    defp bootstrap_conn(api_key) do
      base_conn()
      |> put_req_header("x-loopctl-sth-bootstrap", "true")
      |> with_api_key(api_key)
    end

    test "first bootstrap request is granted and stamps sth_bootstrap_consumed_at" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      assert is_nil(api_key.sth_bootstrap_consumed_at)

      conn = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

      # Grace granted → request continues (not halted), with cache hints.
      refute conn.halted
      assert [_sth] = get_resp_header(conn, "x-loopctl-current-sth")
      assert ["missing_header_bootstrap_grace"] = get_resp_header(conn, "x-loopctl-sth-warning")

      # Consumption is now recorded on the key.
      reloaded = AdminRepo.get!(ApiKey, api_key.id)
      assert %DateTime{} = reloaded.sth_bootstrap_consumed_at
    end

    test "a second bootstrap request from the same key is rejected 412" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})

      # First request consumes the grace.
      _ = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

      # Reload so the struct carries the stamped consumed_at, then retry.
      reloaded = AdminRepo.get!(ApiKey, api_key.id)

      conn = reloaded |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412

      assert Jason.decode!(conn.resp_body)["error"]["code"] ==
               "witness_bootstrap_already_consumed"
    end

    test "no resolved api key (superadmin/absent) does not crash and grants grace" do
      conn =
        base_conn()
        |> put_req_header("x-loopctl-sth-bootstrap", "true")
        |> ValidateWitnessHeader.call(@enforce)

      refute conn.halted
      assert [_sth] = get_resp_header(conn, "x-loopctl-current-sth")
    end
  end
end
