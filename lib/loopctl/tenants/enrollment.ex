defmodule Loopctl.Tenants.Enrollment do
  @moduledoc """
  US-26.7.2 — owns the DB-only `Ecto.Multi` for the opt-in WebAuthn
  trust-tier upgrade ceremony (agent_rooted -> human_anchored) and for
  authenticator revocation.

  `enroll/3` is PHASE 3 of the enrollment ceremony (AC-26.7.2.3). By the
  time it is called, the caller (`LoopctlWeb.TenantAuthenticatorController`)
  has already, in strictly this order:

    1. Consumed the registration challenge in its OWN committed transaction
       (`Loopctl.WebAuthn.Enrollment.consume/2`) — and, if the tenant is
       already `human_anchored`, ALSO verified + consumed a fresh
       `add_authenticator` reauth assertion
       (`Loopctl.WebAuthn.Reauth.verify_and_consume/3`) from an
       ALREADY-enrolled authenticator. This is the critical
       anti-soft-recovery-backdoor gate: a stolen `role: :user` API key
       alone can never add a backup authenticator to an already-anchored
       tenant.
    2. Size-capped and verified the WebAuthn attestation
       (`Loopctl.WebAuthn.verify_registration/3`) OUTSIDE any open
       transaction (CPU-bound CBOR/COSE work never holds a DB connection).

  So `enroll/3` performs NO crypto — it is a pure, atomic DB transaction:
  lock the tenant row, enforce the per-tenant authenticator cap, insert the
  `RootAuthenticator`, GUARD-flip `trust_tier` from `:agent_rooted` to
  `:human_anchored`, and append exactly one audit entry.

  Both `enroll/3` and `revoke/2` open with a `SELECT ... FOR UPDATE` on the
  TENANT row itself (mirroring `Loopctl.AuditChain`'s "lock the latest row to
  serialize concurrent appends" idiom, audit_chain.ex:289) — NOT the
  authenticator rows. A tenant's FIRST enrollment has ZERO authenticator
  rows to lock, so a `FOR UPDATE` on `tenant_root_authenticators` would lock
  nothing and fail to serialize the concurrent-double-first-enroll race
  (AC-26.7.2.8g) or the cap-check race. Locking the tenant row is the
  transaction-scoped, per-tenant mutual-exclusion mechanism the spec
  explicitly allows as an alternative to a `pg_try_advisory_xact_lock`
  (`token_usage.ex:450`) — and, unlike a derived advisory-lock key, it also
  gives us the CURRENT `trust_tier` in the same read, which the guarded flip
  and the revoke last-authenticator guard both need.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.Tenants.Tenant

  # Reuses the signup ceremony's per-tenant cap (Loopctl.Tenants,
  # @max_authenticators_per_signup) so a tenant can never end up with more
  # enrolled authenticators via the upgrade path than via original signup.
  @max_authenticators 5

  @type enroll_result :: %{
          tenant: Tenant.t(),
          authenticator: RootAuthenticator.t(),
          upgraded: boolean()
        }

  @doc "The per-tenant authenticator cap enforced by `enroll/3`."
  @spec max_authenticators() :: pos_integer()
  def max_authenticators, do: @max_authenticators

  @doc """
  PHASE 3 of the enrollment ceremony (AC-26.7.2.3): a DB-only `Ecto.Multi`
  that locks the tenant row, RE-CHECKS the backup-enrollment gate against the
  freshly-locked authoritative tier, enforces the per-tenant authenticator
  cap, inserts the `RootAuthenticator`, GUARD-flips `trust_tier` from
  `:agent_rooted` to `:human_anchored` via a conditional `UPDATE ... WHERE
  trust_tier = 'agent_rooted'` (a no-op, zero-row update if the tenant is
  already `human_anchored` or a racing transaction already flipped it), and
  appends exactly one audit entry — `tenant_trust_upgraded` when THIS call
  performed the flip, `authenticator_enrolled` otherwise.

  `assertion_verified?` records whether PHASE 1 actually verified AND consumed
  a fresh `add_authenticator` assertion from an EXISTING authenticator for
  THIS request. The critical invariant — a backup authenticator can only be
  added to an already-`human_anchored` tenant with proof of possession of an
  existing device — is enforced HERE, under the lock, NOT only in the
  controller's pre-lock read:

    * `assert_gate/2` runs AFTER `lock_tenant/2`, against the freshly-locked
      authoritative `trust_tier`. If the locked tier is `:human_anchored` and
      `assertion_verified?` is not `true`, the Multi is ABORTED with
      `{:error, :reauth_required}` BEFORE `Multi.insert(:authenticator, ...)`.

  This closes the concurrent-double-FIRST-enroll race (AC-26.7.2.8g) as a
  SECURITY property, not just an audit-count one: two concurrent enrollments
  on an `agent_rooted` tenant each read `agent_rooted` pre-lock and skip the
  assertion. The one that wins the tenant-row lock flips to `human_anchored`
  and enrolls (logging `tenant_trust_upgraded`); the loser then acquires the
  lock, sees `human_anchored` + `assertion_verified? == false`, and is
  REJECTED `:reauth_required` — it MUST retry with an `add_authenticator`
  assertion. So an attacker holding a stolen `role:user` key + their own
  hardware can never graft a second device onto a tenant that a legitimate
  first-enroll just anchored: exactly one enrollment wins, and every
  subsequent device must prove possession of an existing one.

  `attrs` is the already-verified attestation result, e.g.
  `%{credential_id:, public_key:, attestation_format:, sign_count:,
  friendly_name:}` — `public_key` must be the verbatim
  `:erlang.term_to_binary(cose_key)` blob `WebAuthn.verify_registration/3`
  returns (`RootAuthenticator.create_changeset/2` stores it as-is).
  """
  @spec enroll(Ecto.UUID.t(), map(), boolean()) ::
          {:ok, enroll_result()}
          | {:error, :not_found}
          | {:error, :reauth_required}
          | {:error, :too_many_authenticators}
          | {:error, Ecto.Changeset.t()}
  def enroll(tenant_id, attrs, assertion_verified?)
      when is_binary(tenant_id) and is_map(attrs) and is_boolean(assertion_verified?) do
    multi =
      Multi.new()
      |> Multi.run(:tenant, fn repo, _changes -> lock_tenant(repo, tenant_id) end)
      |> Multi.run(:assert_gate, fn _repo, %{tenant: tenant} ->
        assert_gate(tenant, assertion_verified?)
      end)
      |> Multi.run(:check_cap, fn repo, _changes -> check_cap(repo, tenant_id) end)
      |> Multi.insert(:authenticator, fn _changes ->
        RootAuthenticator.create_changeset(%RootAuthenticator{tenant_id: tenant_id}, attrs)
      end)
      |> Multi.update_all(:flip_tier, flip_query(tenant_id), set: [trust_tier: :human_anchored])
      |> Multi.run(:reloaded_tenant, fn repo, _changes -> {:ok, repo.get!(Tenant, tenant_id)} end)
      |> Audit.log_in_multi(:audit, &build_enroll_audit_attrs(tenant_id, &1))

    case AdminRepo.transaction(multi) do
      {:ok, %{authenticator: auth, reloaded_tenant: tenant, flip_tier: {flipped, _}}} ->
        on_enroll_success(tenant_id, tenant, auth, flipped)

      {:error, :tenant, :not_found, _changes} ->
        {:error, :not_found}

      {:error, :assert_gate, :reauth_required, _changes} ->
        {:error, :reauth_required}

      {:error, :check_cap, :too_many_authenticators, _changes} ->
        {:error, :too_many_authenticators}

      {:error, :authenticator, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # US-33.3: a first-device enrollment flips the tenant to :human_anchored. The
  # api-key cache stores each key WITH its :tenant preloaded (trust_tier is read by
  # RequireHumanAnchor), so bust the tenant's cached keys on an upgrade — the
  # change must gate custody ops on the very next request, not after the TTL.
  defp on_enroll_success(tenant_id, tenant, auth, flipped) do
    upgraded? = flipped == 1
    if upgraded?, do: Loopctl.Auth.invalidate_tenant_key_cache(tenant_id)
    {:ok, %{tenant: tenant, authenticator: auth, upgraded: upgraded?}}
  end

  # Under-lock backup-enrollment gate. A first enrollment (locked tier still
  # `agent_rooted`) needs no assertion — the flip happens later in THIS same
  # transaction. An already-`human_anchored` tenant needs a verified
  # `add_authenticator` assertion; without one, abort before the insert.
  defp assert_gate(%Tenant{trust_tier: :human_anchored}, false), do: {:error, :reauth_required}
  defp assert_gate(%Tenant{}, _assertion_verified?), do: {:ok, :ok}

  @doc """
  Revokes a single authenticator (AC-26.7.2.4). Callers must have already
  verified a fresh `revoke_authenticator` reauth assertion
  (`Loopctl.WebAuthn.Reauth.verify_and_consume/3`) — this function performs
  no crypto, only the race-safe DB delete.

  RACE-SAFE LAST-AUTHENTICATOR GUARD: locks the tenant row `FOR UPDATE`
  (same mechanism as `enroll/3`) before counting the tenant's authenticators,
  so two concurrent revokes against a 2-authenticator tenant cannot both
  pass — the second waits for the first's transaction to commit, then
  re-counts and sees only 1 remaining. Revoking the LAST authenticator while
  `human_anchored` is refused with `{:error, :last_authenticator}` — no
  auto-downgrade to `agent_rooted`.
  """
  @spec revoke(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RootAuthenticator.t()}
          | {:error, :not_found}
          | {:error, :last_authenticator}
  def revoke(tenant_id, authenticator_id)
      when is_binary(tenant_id) and is_binary(authenticator_id) do
    multi =
      Multi.new()
      |> Multi.run(:tenant, fn repo, _changes -> lock_tenant(repo, tenant_id) end)
      |> Multi.run(:target, fn repo, _changes ->
        find_authenticator(repo, tenant_id, authenticator_id)
      end)
      |> Multi.run(:guard_last, fn repo, %{tenant: tenant} ->
        guard_last_authenticator(repo, tenant_id, tenant)
      end)
      |> Multi.run(:deleted, fn _repo, %{target: auth} ->
        RootAuthenticators.delete(tenant_id, auth.id)
      end)
      |> Audit.log_in_multi(:audit, fn %{deleted: auth} ->
        %{
          tenant_id: tenant_id,
          entity_type: "tenant",
          entity_id: tenant_id,
          action: "authenticator_revoked",
          actor_type: "human",
          actor_id: nil,
          actor_label: "human:webauthn",
          old_state: %{
            "authenticator_fingerprint" => Tenants.fingerprint(auth.credential_id),
            "friendly_name" => auth.friendly_name
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{deleted: auth}} ->
        {:ok, auth}

      {:error, :tenant, :not_found, _changes} ->
        {:error, :not_found}

      {:error, :target, :not_found, _changes} ->
        {:error, :not_found}

      {:error, :guard_last, :last_authenticator, _changes} ->
        {:error, :last_authenticator}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Renames an enrolled authenticator's operator-facing label.

  Deliberately does NOT take the tenant `FOR UPDATE` lock that `enroll/3` and
  `revoke/2` share. That lock exists to serialize mutations that can violate an
  invariant — the per-tenant authenticator cap, the trust-tier flip, and the
  last-authenticator guard. A rename touches none of them: it cannot change how
  many authenticators a tenant has, nor its tier, so the worst outcome of two
  concurrent renames is last-write-wins on a display string. Taking the tenant
  lock anyway would let a label edit block an in-flight enrollment ceremony.

  No reauth assertion is required either, unlike `revoke/2`. A rename is
  reversible, destroys nothing, and is already bounded by the `user` role gate
  and the human-anchor tier gate; demanding a touch would price a typo fix at
  the same cost as destroying a root-of-trust credential. The change is still
  recorded in the append-only audit chain with both the old and new label.
  """
  @spec rename(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, RootAuthenticator.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
  def rename(tenant_id, authenticator_id, friendly_name)
      when is_binary(tenant_id) and is_binary(authenticator_id) and is_binary(friendly_name) do
    multi =
      Multi.new()
      |> Multi.run(:target, fn repo, _changes ->
        find_authenticator(repo, tenant_id, authenticator_id)
      end)
      |> Multi.update(:renamed, fn %{target: auth} ->
        RootAuthenticator.rename_changeset(auth, %{friendly_name: friendly_name})
      end)
      |> Audit.log_in_multi(:audit, fn %{target: old, renamed: auth} ->
        %{
          tenant_id: tenant_id,
          entity_type: "tenant",
          entity_id: tenant_id,
          action: "authenticator_renamed",
          actor_type: "human",
          actor_id: nil,
          actor_label: "human:api",
          old_state: %{
            "authenticator_fingerprint" => Tenants.fingerprint(old.credential_id),
            "friendly_name" => old.friendly_name
          },
          new_state: %{"friendly_name" => auth.friendly_name}
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{renamed: auth}} ->
        {:ok, auth}

      {:error, :target, :not_found, _changes} ->
        {:error, :not_found}

      {:error, :renamed, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Locks the tenant row for the duration of the enclosing transaction —
  # the single mechanism serializing every authenticator mutation
  # (enroll AND revoke) for this tenant, including the zero-row first-enroll
  # case a `FOR UPDATE` on `tenant_root_authenticators` could not cover.
  defp lock_tenant(repo, tenant_id) do
    case from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE") |> repo.one() do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  defp check_cap(repo, tenant_id) do
    count =
      from(a in RootAuthenticator, where: a.tenant_id == ^tenant_id, select: count(a.id))
      |> repo.one()

    if count >= @max_authenticators do
      {:error, :too_many_authenticators}
    else
      {:ok, count}
    end
  end

  defp flip_query(tenant_id) do
    from(t in Tenant, where: t.id == ^tenant_id and t.trust_tier == :agent_rooted)
  end

  defp find_authenticator(repo, tenant_id, authenticator_id) do
    query =
      from a in RootAuthenticator,
        where: a.tenant_id == ^tenant_id and a.id == ^authenticator_id

    case repo.one(query) do
      nil -> {:error, :not_found}
      authenticator -> {:ok, authenticator}
    end
  end

  # Revoking the tenant's LAST authenticator while human_anchored is a
  # deliberate 409 — the docs' "fatal event" (chain-of-custody-v2.md §9.3).
  # No auto-downgrade to agent_rooted is ever performed.
  defp guard_last_authenticator(repo, tenant_id, %Tenant{trust_tier: :human_anchored}) do
    count =
      from(a in RootAuthenticator, where: a.tenant_id == ^tenant_id, select: count(a.id))
      |> repo.one()

    if count <= 1 do
      {:error, :last_authenticator}
    else
      {:ok, count}
    end
  end

  defp guard_last_authenticator(_repo, _tenant_id, %Tenant{}), do: {:ok, :not_gated}

  defp build_enroll_audit_attrs(tenant_id, %{flip_tier: {flipped, _}} = changes) do
    auth = changes.authenticator
    old_tenant = changes.tenant
    new_tenant = changes.reloaded_tenant

    if flipped == 1 do
      %{
        tenant_id: tenant_id,
        entity_type: "tenant",
        entity_id: tenant_id,
        action: "tenant_trust_upgraded",
        actor_type: "human",
        actor_id: nil,
        actor_label: "human:webauthn",
        old_state: %{"trust_tier" => Atom.to_string(old_tenant.trust_tier)},
        new_state: %{
          "trust_tier" => Atom.to_string(new_tenant.trust_tier),
          "authenticator_fingerprint" => Tenants.fingerprint(auth.credential_id)
        }
      }
    else
      %{
        tenant_id: tenant_id,
        entity_type: "tenant",
        entity_id: tenant_id,
        action: "authenticator_enrolled",
        actor_type: "human",
        actor_id: nil,
        actor_label: "human:webauthn",
        new_state: %{
          "authenticator_fingerprint" => Tenants.fingerprint(auth.credential_id),
          "friendly_name" => auth.friendly_name
        }
      }
    end
  end
end
