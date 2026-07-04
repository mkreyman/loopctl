defmodule Loopctl.WebAuthn.Enrollment do
  @moduledoc """
  US-26.7.2 — persisted, single-use, TTL-bound WebAuthn REGISTRATION-challenge
  issuance/consumption for the opt-in trust-tier upgrade ceremony
  (agent_rooted -> human_anchored).

  Reuses ONLY the `ReauthChallenge` PERSISTENCE SHAPE (the schema fields plus
  the atomic single-use `update_all` consume pattern from
  `Loopctl.WebAuthn.Reauth.consume_challenge/3`, reauth.ex:191) via a SEPARATE
  table (`webauthn_enrollment_challenges`,
  `Loopctl.WebAuthn.EnrollmentChallenge`) — NOT `Reauth.issue_challenge/2`
  itself, which hard-requires an existing enrolled authenticator
  (`RootAuthenticators.list_by_tenant/1 != []`) and would make a tenant's
  FIRST enrollment impossible (AC-26.7.2.1).

  `issue/1` calls `Loopctl.WebAuthn.new_registration_challenge/1` directly —
  no existing-authenticator precondition — and persists the challenge
  tenant-scoped with a 300s TTL. `consume/2` atomically single-use-consumes
  it: a guarded `update_all` stamps `used_at` ONLY when the row is unused,
  unexpired, and in-tenant, so a double-spend/replay/cross-tenant attempt
  sees zero rows and a clean `{:error, :challenge_not_found}` — no TOCTOU.

  This module performs NO WebAuthn crypto — it only manages the opaque
  challenge handle. The caller (`LoopctlWeb.TenantAuthenticatorController`)
  consumes the challenge in its OWN committed transaction BEFORE running
  `WebAuthn.verify_registration/3` outside any transaction, per the
  two-phase shape mandated by AC-26.7.2.3.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.WebAuthn
  alias Loopctl.WebAuthn.EnrollmentChallenge

  # Mirrors Reauth's ceremony TTL — the operator is expected to touch their
  # authenticator immediately after requesting the challenge.
  @challenge_ttl_seconds 300
  @purpose "enroll_authenticator"

  @type issue_result :: %{
          challenge_id: Ecto.UUID.t(),
          challenge: term(),
          challenge_bytes: String.t(),
          expires_at: DateTime.t()
        }

  @doc "TTL (seconds) applied to freshly issued enrollment registration challenges."
  @spec challenge_ttl_seconds() :: pos_integer()
  def challenge_ttl_seconds, do: @challenge_ttl_seconds

  @doc """
  Issues and persists a new registration challenge for `tenant_id`. No
  existing-authenticator precondition (unlike `Reauth.issue_challenge/2`) —
  this is exactly what makes FIRST enrollment possible.
  """
  @spec issue(Ecto.UUID.t()) :: {:ok, issue_result()} | {:error, Ecto.Changeset.t()}
  def issue(tenant_id) when is_binary(tenant_id) do
    rp_opts = WebAuthn.rp_opts()
    challenge = WebAuthn.new_registration_challenge(rp_opts)
    expires_at = DateTime.utc_now() |> DateTime.add(@challenge_ttl_seconds, :second)

    attrs = %{
      purpose: @purpose,
      challenge: :erlang.term_to_binary(challenge),
      expires_at: expires_at
    }

    case %EnrollmentChallenge{tenant_id: tenant_id}
         |> EnrollmentChallenge.create_changeset(attrs)
         |> AdminRepo.insert() do
      {:ok, stored} ->
        {:ok,
         %{
           challenge_id: stored.id,
           challenge: challenge,
           challenge_bytes: encode_challenge_bytes(challenge),
           expires_at: expires_at
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Atomically consumes a previously issued registration challenge
  (single-use, TTL-bound, tenant-scoped). PHASE 1 of the enrollment
  ceremony (AC-26.7.2.3): this MUST run and commit in its own transaction
  BEFORE any WebAuthn attestation verification, so a later verification
  failure never un-burns the challenge (replay stays blocked either way).

  Returns `{:ok, challenge}` — the deserialized adapter registration
  challenge struct, ready for `WebAuthn.verify_registration/3` — or
  `{:error, :challenge_not_found}` on any miss (unknown id, wrong tenant,
  already used, or expired — all collapsed to one response so a caller
  cannot distinguish "never existed" from "already consumed" from "expired").
  """
  @spec consume(Ecto.UUID.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, term()}
          | {:error, :challenge_not_found}
          | {:error, :invalid_challenge_id}
          | {:error, :challenge_corrupt}
  def consume(tenant_id, challenge_id) when is_binary(tenant_id) do
    case cast_uuid(challenge_id) do
      {:ok, uuid} -> do_consume(tenant_id, uuid)
      {:error, _} = error -> error
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_challenge_id}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_challenge_id}

  defp do_consume(tenant_id, challenge_id) do
    now = DateTime.utc_now()

    consume_query =
      from(c in EnrollmentChallenge,
        where:
          c.id == ^challenge_id and c.tenant_id == ^tenant_id and c.purpose == ^@purpose and
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
