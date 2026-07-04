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

    test "a DB error while consuming fails closed (412) with a sanitized, SQL-free log" do
      # A malformed (non-UUID) api_key id makes Ecto raise while running the
      # atomic consume, exercising the rescue path: Fix 2 (fail closed, grace not
      # granted) + Fix 3 (sanitized logging, never the raw SQL query text).
      bad_key = %ApiKey{id: "not-a-uuid", tenant_id: Ecto.UUID.generate()}

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          bad_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)
        end)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_missing"

      # Log records the failure but leaks no SQL — struct name / sqlstate only.
      assert log =~ "atomic bootstrap consume failed"
      refute log =~ "query:"
      refute log =~ ~r/SELECT|INSERT|UPDATE/
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

    test "the already-consumed 412 ALWAYS carries a valid current-sth header + retry contract (#298)" do
      # The linchpin that makes a fresh client's retry-once reliable: the
      # bootstrap-already-consumed 412 must ALWAYS hand back the current STH (in
      # the header AND the body) plus a machine-readable retry contract, so the
      # client can cache it and retry the same request without rediscovering the
      # protocol.
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      _server_prefix = insert_sth(api_key.tenant_id, 3)

      _ = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)
      reloaded = AdminRepo.get!(ApiKey, api_key.id)

      conn = reloaded |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

      assert conn.status == 412
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "witness_bootstrap_already_consumed"

      # Header is present and well-formed (position:22-char-base64url-prefix).
      assert [sth] = get_resp_header(conn, "x-loopctl-current-sth")
      assert sth =~ ~r/\A\d+:[A-Za-z0-9_-]{22}\z/

      # The body echoes the same STH and the machine-readable retry contract.
      remediation = body["error"]["remediation"]
      assert remediation["current_sth"] == sth
      assert remediation["retry"]["cache_header"] == "x-loopctl-current-sth"
      assert remediation["retry"]["resend_as"] == "X-Loopctl-Last-Known-STH"
      assert remediation["retry"]["max_retries"] == 1
    end

    test "the already-consumed 412 reuses the read STH — no second audit_signed_tree_heads query (#298 review MEDIUM-7)" do
      # The PR's central efficiency + no-500 claim: the already-consumed 412 hands
      # back the STH read ONCE in consume_grace, never re-querying it. Count the
      # audit_signed_tree_heads reads during the 412 request: exactly one.
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      _server_prefix = insert_sth(api_key.tenant_id, 3)

      _ = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)
      reloaded = AdminRepo.get!(ApiKey, api_key.id)

      sth_queries =
        capture_admin_sth_queries(fn ->
          conn = reloaded |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

          assert conn.status == 412

          assert Jason.decode!(conn.resp_body)["error"]["code"] ==
                   "witness_bootstrap_already_consumed"
        end)

      assert length(sth_queries) == 1,
             "already-consumed 412 must read the STH exactly once (reuse, not re-query), " <>
               "got #{length(sth_queries)}"
    end

    test "consumed-grace 412 emits a distinct telemetry event for the operator" do
      # Observability: the consumed-grace 412 is expected/benign (retryable), so it
      # emits its OWN event — separate from the divergence-alerting path — that an
      # operator can meter without alarm.
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      _ = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)
      reloaded = AdminRepo.get!(ApiKey, api_key.id)

      ref = make_ref()
      test_pid = self()
      handler_id = "witness-bootstrap-consumed-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :witness, :bootstrap_already_consumed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      _conn = reloaded |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

      assert_receive {^ref, [:loopctl, :witness, :bootstrap_already_consumed], %{count: 1},
                      %{tenant_id: tenant_id}}

      assert tenant_id == api_key.tenant_id
    end

    test "atomic consume is single-winner even when the in-memory struct still shows nil (TOCTOU)" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      assert is_nil(api_key.sth_bootstrap_consumed_at)

      # Both requests carry the SAME pre-fetched nil struct — exactly what two
      # concurrent first-requests would read before either writes. The old
      # read-then-write logic granted BOTH; the atomic conditional UPDATE must
      # let exactly one win and reject the other 412.
      conn1 = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)
      conn2 = api_key |> bootstrap_conn() |> ValidateWitnessHeader.call(@enforce)

      conns = [conn1, conn2]
      granted = Enum.count(conns, fn c -> not c.halted end)

      rejected =
        Enum.count(conns, fn c ->
          c.halted and c.status == 412 and
            Jason.decode!(c.resp_body)["error"]["code"] == "witness_bootstrap_already_consumed"
        end)

      assert granted == 1
      assert rejected == 1

      # And the DB reflects a single consumption stamp.
      reloaded = AdminRepo.get!(ApiKey, api_key.id)
      assert %DateTime{} = reloaded.sth_bootstrap_consumed_at
    end

    test "no resolved api key (absent) cannot bootstrap — 412 missing header, no crash" do
      conn =
        base_conn()
        |> put_req_header("x-loopctl-sth-bootstrap", "true")
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_missing"
    end
  end

  describe "FIX 2 — a future position cannot skip the divergence check" do
    test "position beyond the latest sealed STH returns 409 resync, no pass-through, no halt" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      tenant_id = api_key.tenant_id
      # Latest sealed STH is at position 5; nothing exists at/after 999_999_999.
      insert_sth(tenant_id, 5)

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "999999999:#{@other_prefix}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      # Must NOT pass through — it is halted with the resync 409.
      assert conn.halted
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_divergence"

      assert [hint] = get_resp_header(conn, "x-loopctl-current-sth")
      assert hint =~ ~r/\A\d+:[A-Za-z0-9_-]{22}\z/

      # And custody is NOT halted by this raw client input.
      {:ok, tenant} = Tenants.get_tenant(tenant_id)
      refute Tenants.custody_halted?(tenant)
    end
  end

  describe "FIX 3 — oversized position is rejected, not a 500" do
    test "a position larger than bigint max returns 412 malformed (no Postgrex encode 500)" do
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      insert_sth(api_key.tenant_id, 5)

      conn =
        base_conn()
        |> put_req_header(
          "x-loopctl-last-known-sth",
          "99999999999999999999999999:#{@other_prefix}"
        )
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_header_malformed"
    end
  end

  describe "FIX #298 review HIGH-3 — fresh-tenant zero-STH placeholder does not 409-loop" do
    # base64url(no padding) of 16 zero bytes — the all-zero placeholder the
    # bootstrap grace issues while a tenant has no sealed STH yet.
    @zero_prefix Base.url_encode64(:binary.copy(<<0>>, 16), padding: false)

    test "echoing the zero-STH placeholder PASSES when the tenant has no sealed STH" do
      # A new tenant has a ~60s window (before ComputeSthWorker seals its first
      # STH) where the bootstrap hands out `0:<zero_prefix>`. A subsequent request
      # echoing exactly that must NOT 409 — there is nothing to diverge from, and
      # the 412-only client retry could never recover from a 409 here.
      {_raw, api_key} = fixture(:api_key, %{role: :agent})

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "0:#{@zero_prefix}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      refute conn.halted
      assert is_nil(conn.status)
    end

    test "the zero-STH placeholder is NOT a free pass once a real STH is sealed" do
      # Discriminating: once the tenant has a sealed STH, the zero placeholder no
      # longer matches (get_sth_at_position finds the real STH) → genuine 409. The
      # pass-through is gated strictly on there being NO sealed STH.
      {_raw, api_key} = fixture(:api_key, %{role: :agent})
      insert_sth(api_key.tenant_id, 5)

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "0:#{@zero_prefix}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_divergence"
    end

    test "a non-zero position with no sealed STH still resyncs (only the zero placeholder passes)" do
      # The pass-through is scoped to position 0 + the zero prefix. A client that
      # claims some other position while nothing is sealed cannot have gotten it
      # from us → resync, never a bypass.
      {_raw, api_key} = fixture(:api_key, %{role: :agent})

      conn =
        base_conn()
        |> put_req_header("x-loopctl-last-known-sth", "7:#{@other_prefix}")
        |> with_api_key(api_key)
        |> ValidateWitnessHeader.call(@enforce)

      assert conn.halted
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "witness_divergence"
    end
  end

  # Captures the SQL of every audit_signed_tree_heads query the AdminRepo runs
  # inside `fun`, scoped to self() so concurrent async tests don't leak in.
  defp capture_admin_sth_queries(fun) do
    test_pid = self()
    handler_id = "sth-query-capture-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:loopctl, :admin_repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid and String.contains?(query, "audit_signed_tree_heads") do
          send(test_pid, {:sth_query, query})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_sth_queries([])
  end

  defp drain_sth_queries(acc) do
    receive do
      {:sth_query, q} -> drain_sth_queries([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
