defmodule Loopctl.WebAuthn.Reauth do
  @moduledoc """
  crypto-01 (GHSA-c3cw-5f7p-g76r) — challenge-bound WebAuthn
  reauthentication for chain-of-custody-critical operations.

  This replaces the placeholder that generated a brand-new server-side
  challenge and immediately "verified" the same raw blob against an empty
  authenticator list (no challenge binding, no signature check). The real
  ceremony is two-step and mirrors the signup registration ceremony:

    1. `issue_challenge/2` generates an authentication challenge via the
       configured `Loopctl.WebAuthn` adapter, binds the tenant's enrolled
       `RootAuthenticator` credentials to it (`allow_credentials`), stores
       it server-side (`ReauthChallenge`, short TTL, single-use) and hands
       the opaque `challenge_id` + allowed credential ids to the client.

    2. `verify_and_consume/3` atomically consumes the STORED challenge
       (single-use — a racing/duplicate attempt sees zero rows), looks up
       the enrolled authenticator for THIS tenant by `credential_id`
       (rejecting unknown/foreign credentials), verifies the assertion
       against the stored challenge and the authenticator's stored COSE
       public key (origin + RP-ID + signature), rejects sign-counter
       regression, and persists the new counter on success.

  Every function fails CLOSED: any decode error, missing/expired/reused
  challenge, unknown credential, invalid signature, or counter regression
  returns `{:error, reason}` and rotates nothing.

  All queries run on `Loopctl.AdminRepo` and are explicitly scoped by
  `tenant_id`, matching `Loopctl.Tenants.RootAuthenticators`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.WebAuthn
  alias Loopctl.WebAuthn.ReauthChallenge

  # Reauth challenges are short-lived — the operator has just clicked
  # "rotate" and is expected to touch their authenticator immediately.
  @challenge_ttl_seconds 300

  @type issue_result :: %{
          challenge_id: Ecto.UUID.t(),
          challenge: String.t(),
          allowed_credentials: [String.t()],
          rp_id: String.t() | nil,
          expires_at: DateTime.t()
        }

  @type assertion_params :: %{
          optional(String.t()) => String.t()
        }

  @doc "TTL (seconds) applied to freshly issued reauth challenges."
  @spec challenge_ttl_seconds() :: pos_integer()
  def challenge_ttl_seconds, do: @challenge_ttl_seconds

  @doc """
  Issues a reauth challenge bound to `tenant_id` for `purpose`.

  Loads the tenant's enrolled root authenticators, embeds them as
  `allow_credentials` in a fresh authentication challenge, persists the
  challenge server-side (single-use, TTL-bounded), and returns the opaque
  handle plus the base64url credential ids the client should offer to
  `navigator.credentials.get()`.

  Returns `{:error, :no_authenticators}` when the tenant has enrolled no
  root authenticator (nothing could authorize the ceremony).
  """
  @spec issue_challenge(Ecto.UUID.t(), String.t()) ::
          {:ok, issue_result()} | {:error, term()}
  def issue_challenge(tenant_id, purpose)
      when is_binary(tenant_id) and is_binary(purpose) do
    case RootAuthenticators.list_by_tenant(tenant_id) do
      [] ->
        {:error, :no_authenticators}

      authenticators ->
        do_issue_challenge(tenant_id, purpose, authenticators)
    end
  end

  defp do_issue_challenge(tenant_id, purpose, authenticators) do
    rp_opts = WebAuthn.rp_opts()

    # crypto-01: do NOT embed :allow_credentials in the PERSISTED challenge. The
    # stored `public_key` is raw `:erlang.term_to_binary(cose_map)` bytes; embedding
    # those verbatim into `%Wax.Challenge{}.allow_credentials` makes Wax use the raw
    # binary AS the COSE key (its non-empty allow_credentials branch wins over the
    # correctly-decoded 6th-arg credentials), so `Wax.CoseKey.verify` hits its
    # unsupported-algorithm catch-all and ALWAYS rejects — even a valid signature.
    # The enrolled credentials are supplied (decoded) ONLY at verify time via the
    # adapter's `:allow_credentials` opt, which is Wax's documented
    # self-discoverable-credentials contract (the 6th arg is consulted exactly when
    # `challenge.allow_credentials == []`). The client still receives the allowed
    # credential ids below — built independently from `authenticators`, NOT from the
    # challenge struct.
    challenge = WebAuthn.new_authentication_challenge(rp_opts)

    expires_at =
      DateTime.utc_now() |> DateTime.add(@challenge_ttl_seconds, :second)

    attrs = %{
      purpose: purpose,
      challenge: :erlang.term_to_binary(challenge),
      expires_at: expires_at
    }

    case %ReauthChallenge{tenant_id: tenant_id}
         |> ReauthChallenge.create_changeset(attrs)
         |> AdminRepo.insert() do
      {:ok, stored} ->
        {:ok,
         %{
           challenge_id: stored.id,
           challenge: encode_challenge_bytes(challenge),
           allowed_credentials:
             Enum.map(authenticators, &Base.url_encode64(&1.credential_id, padding: false)),
           rp_id: Keyword.get(rp_opts, :rp_id),
           expires_at: expires_at
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Verifies a WebAuthn assertion against a previously issued, STORED
  challenge and consumes that challenge (single-use).

  `params` is the raw request body for the assertion, with base64url
  string values under the keys:

    - `"challenge_id"`      — the opaque handle from `issue_challenge/2`
    - `"credential_id"`     — the asserting credential id
    - `"authenticator_data"`— raw authenticator data
    - `"signature"`         — the assertion signature
    - `"client_data_json"`  — the raw client data JSON

  On success returns `{:ok, %{signature: binary(), sign_count: n,
  authenticator: %RootAuthenticator{}}}` — `signature` is the genuinely
  verified assertion signature, suitable for persistence as the rotation
  proof. On any failure returns `{:error, reason}` and rotates nothing;
  the challenge is consumed regardless (one challenge authorizes at most
  one attempt).
  """
  @spec verify_and_consume(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, %{signature: binary(), sign_count: non_neg_integer(), authenticator: term()}}
          | {:error, term()}
  def verify_and_consume(tenant_id, purpose, params)
      when is_binary(tenant_id) and is_binary(purpose) and is_map(params) do
    with {:ok, challenge_id} <- fetch_uuid(params, "challenge_id"),
         {:ok, credential_id} <- fetch_b64(params, "credential_id"),
         {:ok, authenticator_data} <- fetch_b64(params, "authenticator_data"),
         {:ok, signature} <- fetch_b64(params, "signature"),
         {:ok, client_data_json} <- fetch_b64(params, "client_data_json"),
         {:ok, challenge} <- consume_challenge(tenant_id, purpose, challenge_id),
         {:ok, authenticator} <-
           RootAuthenticators.get_by_credential_id(tenant_id, credential_id),
         {:ok, %{sign_count: new_count}} <-
           WebAuthn.verify_authentication(
             %{
               credential_id: credential_id,
               authenticator_data: authenticator_data,
               signature: signature,
               client_data_json: client_data_json
             },
             challenge,
             allow_credentials: [{authenticator.credential_id, authenticator.public_key}]
           ),
         {:ok, updated} <- persist_counter(authenticator, new_count) do
      {:ok, %{signature: signature, sign_count: new_count, authenticator: updated}}
    else
      {:error, reason} = error ->
        Logger.info("WebAuthn reauth rejected (#{purpose}): #{inspect(reason)}")
        error
    end
  end

  # Atomic single-use consume: a guarded `update_all` stamps `used_at`
  # ONLY when the row is unused, unexpired, and in-tenant for this
  # purpose, and the same statement's RETURNING (`select: c.challenge`)
  # hands back the serialized challenge. A double-spend loser sees 0 rows.
  defp consume_challenge(tenant_id, purpose, challenge_id) do
    now = DateTime.utc_now()

    consume_query =
      from(c in ReauthChallenge,
        where:
          c.id == ^challenge_id and c.tenant_id == ^tenant_id and c.purpose == ^purpose and
            is_nil(c.used_at) and c.expires_at > ^now,
        select: c.challenge
      )

    Multi.new()
    |> Multi.update_all(:consume, consume_query, set: [used_at: now])
    |> Multi.run(:assert_consumed, &assert_consumed/2)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{assert_consumed: challenge}} -> {:ok, challenge}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp assert_consumed(_repo, %{consume: {1, [serialized]}}),
    do: deserialize_challenge(serialized)

  defp assert_consumed(_repo, _changes), do: {:error, :challenge_not_found}

  # crypto-01: ATOMIC counter check-and-persist. A single conditional UPDATE both
  # enforces monotonicity and persists the new counter, closing the TOCTOU where
  # two concurrent assertions from a cloned/replayed authenticator both read the
  # old counter, both pass a separate check, and both rotate. 0 rows affected ⇒
  # the counter did not strictly advance (clone/replay) ⇒ reject.
  #
  # WebAuthn §7.2 step 21: a stored/new counter of 0/0 means the authenticator
  # implements no signature counter, which the spec permits — the `sign_count == 0`
  # branch accepts that (and touches `last_used_at`) while still rejecting a drop
  # from a previously-nonzero counter back to 0 (clone signal).
  defp persist_counter(%RootAuthenticator{} = authenticator, new_count)
       when is_integer(new_count) and new_count >= 0 do
    now = DateTime.utc_now()

    query =
      if new_count == 0 do
        from(a in RootAuthenticator, where: a.id == ^authenticator.id and a.sign_count == 0)
      else
        from(a in RootAuthenticator,
          where: a.id == ^authenticator.id and a.sign_count < ^new_count
        )
      end

    case AdminRepo.update_all(query, set: [sign_count: new_count, last_used_at: now]) do
      {1, _} -> {:ok, %{authenticator | sign_count: new_count, last_used_at: now}}
      {0, _} -> {:error, :counter_regression}
    end
  end

  defp fetch_uuid(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, {:invalid_field, key}}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp fetch_b64(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" ->
        decode_b64url(value, key)

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp decode_b64url(value, key) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        case Base.decode64(value, padding: false) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, {:invalid_field, key}}
        end
    end
  end

  # The stored blob is our own `term_to_binary` output, not user input.
  # `[:safe]` still guards against decoding funs/new atoms if the row were
  # ever tampered with. A corrupt/undecodable blob fails CLOSED rather than
  # letting a nil challenge reach the adapter.
  defp deserialize_challenge(serialized) when is_binary(serialized) do
    {:ok, :erlang.binary_to_term(serialized, [:safe])}
  rescue
    _ -> {:error, :challenge_corrupt}
  end

  defp encode_challenge_bytes(%{bytes: bytes}) when is_binary(bytes),
    do: Base.url_encode64(bytes, padding: false)

  defp encode_challenge_bytes(bytes) when is_binary(bytes),
    do: Base.url_encode64(bytes, padding: false)

  defp encode_challenge_bytes(_), do: ""
end
