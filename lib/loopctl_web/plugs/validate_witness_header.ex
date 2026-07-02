defmodule LoopctlWeb.Plugs.ValidateWitnessHeader do
  @moduledoc """
  US-26.5.2 — Validates the X-Loopctl-Last-Known-STH header on
  authenticated requests.

  The header format is: `<position>:<base64url_sig_prefix>` where the
  signature prefix is the base64url (no padding) encoding of the first
  16 bytes of the STH signature — always exactly 22 characters.

  - Missing header → 412 Precondition Failed (`witness_header_missing`).
  - Malformed header (bad split, non-integer position, or a signature
    prefix that is not exactly 22 base64url chars) → 412
    (`witness_header_malformed`).
  - Signature-prefix mismatch against the server's STH → 409
    (`witness_divergence`) with the server's current STH in the
    `x-loopctl-current-sth` response header so a stale client can resync.

  ## Custody safety (private advisories)

  This plug operates on **raw, unauthenticated client input** and therefore
  must never, on its own, treat a mismatch as proof of byzantine divergence:

  * custody-01 (GHSA-w786-f588-2943): a client-supplied prefix mismatch does
    NOT halt the tenant. A raw mismatch almost always means the caller's
    cached STH is stale, not that the log forked. We respond 409 + resync
    hint and emit telemetry for monitoring. Genuine byzantine halts stay with
    the trust-violation paths in `LoopctlWeb.FallbackController` and the
    signed-STH verifier — this plug halts custody for no client-driven reason.
  * custody-02 (GHSA-cxrw-xg8f-mx8v): the comparison window is derived from
    the fixed-length SERVER value, never from client input, and the client
    prefix is length/charset validated up front so an empty or short prefix
    cannot evade the divergence check.
  * custody-03 (GHSA-36g5-mcrh-rcrm): the bootstrap grace is one-time per API
    key (`api_keys.sth_bootstrap_consumed_at`), so a caller cannot send
    `X-Loopctl-STH-Bootstrap: true` on every request to skip validation.
  """

  @behaviour Plug

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Auth.ApiKey

  # base64url(no padding) of the first 16 bytes of the signature is always
  # exactly 22 characters. This is the ONLY accepted client prefix length —
  # the comparison window is fixed by the server, not by client input.
  @sig_prefix_length 22
  # chain_position is a Postgres bigint; reject anything outside the signed
  # 64-bit range up front so an oversized (arbitrary-precision) Elixir int
  # never reaches the query and raises a DBConnection.EncodeError (custody-03b).
  # Single source of truth: AuditChain also enforces this bound defensively.
  @max_chain_position AuditChain.max_chain_position()
  @zero_sth_prefix Base.url_encode64(:binary.copy(<<0>>, 16), padding: false)
  @zero_sth "0:#{@zero_sth_prefix}"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    if enforce?(opts) do
      enforce(conn)
    else
      conn
    end
  end

  # Enforcement is config-gated (disabled in test via config/test.exs) but can
  # be forced on per-call via the `:enforce` plug opt — the dedicated plug tests
  # exercise enforcement without an `Application.put_env` (forbidden in tests).
  defp enforce?(opts) do
    case Keyword.fetch(opts, :enforce) do
      {:ok, value} -> value
      :error -> Application.get_env(:loopctl, :enforce_witness_header, true)
    end
  end

  defp enforce(conn) do
    case get_req_header(conn, "x-loopctl-last-known-sth") do
      [header] ->
        validate_header(conn, header)

      [] ->
        # Bootstrap grace: a new dispatch's FIRST request may opt in with
        # `X-Loopctl-STH-Bootstrap: true` to receive the current STH in the
        # response headers so it can cache it. The grace is one-time per API
        # key (custody-03) — after that the key must send a real header.
        if bootstrap_requested?(conn) do
          handle_bootstrap_grace(conn)
        else
          missing_header(conn)
        end
    end
  end

  defp validate_header(conn, header) do
    case String.split(header, ":", parts: 2) do
      [position_str, sig_prefix] ->
        if valid_sig_prefix?(sig_prefix) do
          # US-26.5.2 AC-3: compare against the server's STH.
          check_divergence(conn, position_str, sig_prefix)
        else
          # custody-02: an empty/short/long/non-base64url prefix must be
          # rejected rather than silently comparing an attacker-chosen window.
          malformed(
            conn,
            "X-Loopctl-Last-Known-STH signature prefix must be exactly " <>
              "#{@sig_prefix_length} base64url characters"
          )
        end

      _ ->
        Logger.warning("ValidateWitnessHeader: malformed header: #{inspect(header)}")
        malformed(conn, "X-Loopctl-Last-Known-STH header is malformed")
    end
  end

  defp check_divergence(conn, position_str, sig_prefix) do
    # Resolve tenant from conn (set by SetTenant plug earlier in pipeline)
    tenant_id = get_tenant_id(conn)

    if tenant_id do
      case Integer.parse(position_str) do
        {position, ""} when position >= 0 and position <= @max_chain_position ->
          compare_against_server_sth(conn, tenant_id, position, sig_prefix)

        _ ->
          # custody-03b: rejects negatives, non-integers, AND values beyond the
          # Postgres bigint range BEFORE the query, so an oversized position
          # yields a 412 rather than a 500 from Postgrex.
          malformed(
            conn,
            "Position must be a non-negative integer within the signed 64-bit range"
          )
      end
    else
      # No tenant context (superadmin or public) — skip divergence check.
      conn
    end
  end

  defp compare_against_server_sth(conn, tenant_id, position, sig_prefix) do
    case AuditChain.get_sth_at_position(tenant_id, position) do
      nil ->
        # custody-02: NO pass-through. The server is the SOLE source of STHs, so
        # a position beyond the tenant's latest sealed STH is not something an
        # honest agent can know (its cached position is always <= latest sealed).
        # Treat it as resync-required, never a silent bypass.
        resync_required(conn, tenant_id, position, sig_prefix, "future_position")

      sth ->
        server_prefix = server_sig_prefix(sth.signature)

        # Constant-time compare of two fixed-length, server-derived-length
        # strings. `sig_prefix` was already validated to @sig_prefix_length.
        if Plug.Crypto.secure_compare(server_prefix, sig_prefix) do
          conn
        else
          resync_required(conn, tenant_id, position, sig_prefix, "prefix_mismatch")
        end
    end
  end

  # custody-01/02: a raw client-supplied prefix mismatch OR an unverifiable
  # (future) position is NOT proof of a fork — it is almost always a stale
  # client cache. Do NOT halt the tenant. Tell the client to resync (handing it
  # the current STH) and emit telemetry so genuine divergence can be
  # monitored/alerted out-of-band. Shared by the prefix-mismatch and
  # future-position cases so they return the identical 409 + resync response.
  defp resync_required(conn, tenant_id, position, sig_prefix, reason) do
    Logger.warning(
      "WITNESS DIVERGENCE (client-reported, NOT halting): tenant=#{tenant_id} " <>
        "position=#{position} reason=#{reason} client_prefix=#{sig_prefix}"
    )

    :telemetry.execute(
      [:loopctl, :witness, :divergence],
      %{count: 1},
      %{tenant_id: tenant_id, position: position, reason: reason}
    )

    conn
    |> put_status(:conflict)
    |> put_resp_header("x-loopctl-current-sth", current_sth_value(tenant_id))
    |> Phoenix.Controller.json(%{
      error: %{
        code: "witness_divergence",
        status: 409,
        message:
          "Your cached STH does not match the server. Re-sync from the " <>
            "x-loopctl-current-sth response header and retry. Custody has NOT been halted.",
        remediation: %{
          learn_more: "https://loopctl.com/wiki/witness-protocol"
        }
      }
    })
    |> halt()
  end

  # custody-03: one-time bootstrap grace, made ATOMIC and DB-authoritative to
  # close a read-then-write TOCTOU race — the in-memory struct's nil is NOT
  # trusted. A single conditional UPDATE guarded by the NULL predicate decides
  # the winner: exactly one concurrent first-request flips the column (count 1)
  # and is granted; every other (count 0) is already consumed and rejected.
  defp handle_bootstrap_grace(conn) do
    case conn.assigns[:current_api_key] do
      %ApiKey{id: id, tenant_id: tenant_id} when is_binary(id) ->
        atomic_consume_bootstrap(conn, id, tenant_id)

      _ ->
        # No resolved API key row to record consumption on — cannot grant a
        # bounded one-time grace, so require the real header (fail closed).
        # Defensive: the authenticated pipeline sets current_api_key first.
        missing_header(conn)
    end
  end

  defp atomic_consume_bootstrap(conn, id, tenant_id) do
    # Read the STH the client will cache BEFORE consuming the one-time grace.
    # This lookup is read-only and idempotent, so doing it first means a
    # transient read failure raises here — with the grace NOT yet consumed
    # (rescued to a retryable missing_header) — instead of AFTER the UPDATE has
    # already burned the grace, which would permanently strand the key.
    sth_value = current_sth_value(tenant_id)

    {count, _} =
      from(a in ApiKey, where: a.id == ^id and is_nil(a.sth_bootstrap_consumed_at))
      |> AdminRepo.update_all(set: [sth_bootstrap_consumed_at: DateTime.utc_now()])

    case count do
      # Winner: grant the grace. Only pure response-header setting remains after
      # the committed UPDATE, so nothing here can fail and strand the client.
      1 -> grant_bootstrap_grace(conn, sth_value)
      0 -> bootstrap_already_consumed(conn)
    end
  rescue
    exception ->
      # Fail closed on a DB error BEFORE the grace is consumed (the STH read or
      # the UPDATE itself): never grant an unbounded/repeatable grace, and never
      # burn the one-time grace on a transient failure — this path is retryable.
      Logger.warning(
        "ValidateWitnessHeader: atomic bootstrap consume failed for " <>
          "api_key=#{id}: #{sanitized_db_error(exception)}"
      )

      missing_header(conn)
  end

  defp grant_bootstrap_grace(conn, sth_value) do
    conn
    |> put_resp_header("x-loopctl-current-sth", sth_value)
    |> put_resp_header("x-loopctl-sth-warning", "missing_header_bootstrap_grace")
  end

  # Never inspect/1 a raw DB exception: %Postgrex.Error{} carries the literal SQL
  # statement in its :query field. Log only the struct name + SQLSTATE, matching
  # the US-27.3 sanitized-logging convention used elsewhere.
  defp sanitized_db_error(%Postgrex.Error{postgres: %{code: code}}),
    do: "Postgrex.Error sqlstate=#{code}"

  defp sanitized_db_error(exception), do: inspect(exception.__struct__)

  defp bootstrap_already_consumed(conn) do
    conn
    |> put_status(:precondition_failed)
    |> put_resp_header("x-loopctl-current-sth", current_sth_value(get_tenant_id(conn)))
    |> Phoenix.Controller.json(%{
      error: %{
        code: "witness_bootstrap_already_consumed",
        status: 412,
        message:
          "This API key has already used its one-time STH bootstrap grace. " <>
            "Include the X-Loopctl-Last-Known-STH header (position:prefix) on " <>
            "every subsequent request. The current STH is in the " <>
            "x-loopctl-current-sth response header.",
        remediation: %{
          learn_more: "https://loopctl.com/wiki/witness-protocol"
        }
      }
    })
    |> halt()
  end

  defp missing_header(conn) do
    conn
    |> put_status(:precondition_failed)
    |> Phoenix.Controller.json(%{
      error: %{
        code: "witness_header_missing",
        status: 412,
        message:
          "X-Loopctl-Last-Known-STH header is required. " <>
            "On your first request, include X-Loopctl-STH-Bootstrap: true " <>
            "to receive the current STH in the response headers.",
        remediation: %{
          learn_more: "https://loopctl.com/wiki/witness-protocol"
        }
      }
    })
    |> halt()
  end

  defp malformed(conn, message) do
    conn
    |> put_status(:precondition_failed)
    |> Phoenix.Controller.json(%{
      error: %{
        code: "witness_header_malformed",
        status: 412,
        message: message
      }
    })
    |> halt()
  end

  # --- helpers ---

  defp bootstrap_requested?(conn) do
    get_req_header(conn, "x-loopctl-sth-bootstrap") == ["true"]
  end

  # base64url(no padding) of the first 16 bytes of the signature. For any
  # ed25519 signature (64 bytes) this is exactly @sig_prefix_length chars.
  defp server_sig_prefix(signature) when is_binary(signature) do
    signature
    |> binary_part(0, min(byte_size(signature), 16))
    |> Base.url_encode64(padding: false)
  end

  # The `<position>:<prefix>` value handed back to clients so they can cache /
  # resync. Falls back to the all-zero STH when the tenant has no STH yet.
  defp current_sth_value(nil), do: @zero_sth

  defp current_sth_value(tenant_id) do
    case AuditChain.get_latest_sth(tenant_id) do
      nil -> @zero_sth
      sth -> "#{sth.chain_position}:#{server_sig_prefix(sth.signature)}"
    end
  end

  defp valid_sig_prefix?(prefix) do
    String.length(prefix) == @sig_prefix_length and
      String.match?(prefix, ~r/\A[A-Za-z0-9_-]+\z/)
  end

  defp get_tenant_id(conn) do
    case conn.assigns do
      %{current_api_key: %{tenant_id: tid}} when not is_nil(tid) -> tid
      _ -> nil
    end
  end
end
