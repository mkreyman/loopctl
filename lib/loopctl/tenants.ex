defmodule Loopctl.Tenants do
  @moduledoc """
  Context module for tenant management.

  Tenants are the root organizational unit. They are NOT tenant-scoped
  (no RLS) because the tenants table is queried by the auth pipeline
  before tenant context is set.

  All queries use `AdminRepo` since tenants have no `tenant_id`
  and are not subject to RLS policies.
  """

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.AuditChain
  alias Loopctl.Auth
  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Secrets
  alias Loopctl.TenantKeys
  alias Loopctl.Tenants.AuditKeyHistory
  alias Loopctl.Tenants.CustodyOwnerKeyHistory
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.OrphanedSecretCleanupWorker

  @max_authenticators_per_signup 5
  @pending_enrollment_ttl_seconds 15 * 60

  @doc """
  Creates a new tenant with the given attributes.

  ## Examples

      iex> create_tenant(%{name: "Acme", slug: "acme", email: "a@acme.com"})
      {:ok, %Tenant{}}

      iex> create_tenant(%{name: "Acme"})
      {:error, %Ecto.Changeset{}}
  """
  @spec create_tenant(map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc """
  US-26.0.1 — atomic tenant signup ceremony with WebAuthn enrollment.

  The flow is wrapped in a single `Ecto.Multi` so a single failing
  attestation rolls back every side effect (tenant, authenticators,
  audit entries).

  ## Params

  Takes a single map with:
  - `:name` — tenant display name (required)
  - `:slug` — unique slug (required, validated)
  - `:email` — contact email (required, validated)
  - `:authenticators` — list of maps in the form
    `%{attestation_result: %{credential_id, public_key, attestation_format, sign_count}, friendly_name: "..."}`
    (required, length 1..5)

  The caller is responsible for running WebAuthn verification on each
  browser response and passing the normalized `attestation_result`
  alongside the operator-supplied `friendly_name`.

  ## Returns

  - `{:ok, %{tenant: %Tenant{}, root_authenticators: [%RootAuthenticator{}], raw_key: String.t()}}`
    — `raw_key` is the tenant's root `:user` API key, returned ONCE and never persisted
    in plaintext (#500).
  - `{:error, :no_authenticators}` — empty list
  - `{:error, :too_many_authenticators}` — more than 5
  - `{:error, :slug_taken}` | `{:error, :email_taken}`
  - `{:error, {:audit_key_storage_failed, term()}}` — the secret store rejected the audit
    key (e.g. off Fly with no `SECRETS_ADAPTER`); the whole signup rolled back (#496)
  - `{:error, %Ecto.Changeset{}}` — validation failure
  """
  @spec signup(map()) ::
          {:ok,
           %{
             tenant: Tenant.t(),
             root_authenticators: [RootAuthenticator.t()],
             raw_key: String.t()
           }}
          | {:error, :no_authenticators}
          | {:error, :too_many_authenticators}
          | {:error, :slug_taken}
          | {:error, :email_taken}
          | {:error, {:audit_key_storage_failed, term()}}
          | {:error, Ecto.Changeset.t()}
  def signup(attrs) when is_map(attrs) do
    authenticators = Map.get(attrs, :authenticators) || Map.get(attrs, "authenticators") || []

    cond do
      authenticators == [] ->
        {:error, :no_authenticators}

      length(authenticators) > @max_authenticators_per_signup ->
        {:error, :too_many_authenticators}

      true ->
        do_signup(attrs, authenticators)
    end
  end

  defp do_signup(attrs, authenticators) do
    # Drop the `authenticators` key from the changeset input so cast/3
    # does not stumble over the mixed-key map.
    tenant_attrs = Map.drop(attrs, [:authenticators, "authenticators"])

    # US-26.7.1 (#9) — keypair + deterministic secret name are ordinary lexical
    # variables here, so `with_secret_compensation/3` reads them directly on
    # both the tuple AND the raised-exception paths (no process dictionary).
    # secret_name is derived from the SAME normalized slug the changeset
    # produces, so it matches the inserted `tenant.slug`.
    {pub, priv} = generate_ed25519_keypair()
    secret_name = signup_secret_name(tenant_attrs)

    multi =
      Multi.new()
      |> Multi.insert(:tenant, Tenant.signup_changeset(tenant_attrs))
      |> insert_authenticators(authenticators)
      |> append_keypair_and_genesis(
        secret_name,
        priv,
        pub,
        "human",
        "human:webauthn",
        &signup_new_state/2
      )
      # #500: mint the tenant's root `:user` API key in the SAME transaction, mirroring
      # `self_signup/2`. Without it a browser-onboarded tenant has an anchored tenant but
      # an empty `api_keys` — no authenticated path forward (the onboarding page tells you
      # to call `set_llm_config`, but you have no key to authenticate that call). The raw
      # key is returned ONCE (never persisted in plaintext) for the LiveView to surface;
      # agent/orchestrator keys are minted later, after registering an agent identity.
      |> Multi.run(:root_api_key, fn _repo, %{activate: tenant} ->
        Auth.generate_api_key(%{
          tenant_id: tenant.id,
          name: "root",
          role: :user,
          agent_id: nil
        })
      end)

    result =
      with_secret_compensation({:delete, secret_name}, :store_secret, fn ->
        AdminRepo.transaction(multi)
      end)

    case result do
      {:ok,
       %{activate: tenant, authenticators: authenticators, root_api_key: {raw_key, _api_key}}} ->
        {:ok, %{tenant: tenant, root_authenticators: authenticators, raw_key: raw_key}}

      {:error, :tenant, %Ecto.Changeset{} = changeset, _changes} ->
        signup_changeset_error(changeset)

      {:error, {:authenticator, _index}, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp signup_new_state(%{activate: tenant, authenticators: auths}, pub) do
    %{
      "name" => tenant.name,
      "slug" => tenant.slug,
      "email" => tenant.email,
      "authenticator_count" => length(auths),
      "authenticator_fingerprints" => Enum.map(auths, &fingerprint(&1.credential_id)),
      "audit_signing_public_key" => Base.encode64(pub)
    }
  end

  @doc """
  US-26.7.1 — agent-rooted self-signup: creates a tenant WITHOUT a WebAuthn
  ceremony, entirely through this single API call. The tenant lands on the
  KB tier (`trust_tier: :agent_rooted`) — it retains the full knowledge-wiki
  surface but is blocked (via `LoopctlWeb.Plugs.RequireHumanAnchor`) from the
  work-breakdown / chain-of-custody surface until it opts into a WebAuthn
  enrollment ceremony (US-26.7.2, out of scope here).

  Mirrors the trusted parts of `signup/1` (ed25519 audit keypair generation
  + storage, activation, genesis audit entry via the shared
  `append_keypair_and_genesis/6` helper — including the transactional secret
  compensation in `with_secret_compensation/3`) but does NOT insert any
  `RootAuthenticator`, and stamps `actor_type: "agent"` /
  `actor_label: "agent:self-signup"` on the genesis entry instead of the
  human/webauthn label. It then mints a `role: :user`, `agent_id: nil` root
  API key bound to the tenant so the caller can immediately configure its
  own BYO LLM keys (`PATCH /tenants/me/llm-config`) and register its own
  agent identity (`POST /agents/register`).

  `attrs` accepts `:name`, `:slug`, `:email` (identical validation to
  `signup/1`). Any other key (`trust_tier`, `role`, `tenant_id`, `agent_id`,
  ...) is silently ignored — `Tenant.self_signup_changeset/2`'s cast list is
  `[:name, :slug, :email]`, so mass-assignment is structurally closed.

  ## Returns

  - `{:ok, %{tenant: %Tenant{}, raw_key: String.t()}}` — `raw_key` is
    returned exactly once and is never persisted in plaintext.
  - `{:error, :slug_taken} | {:error, :email_taken}`
  - `{:error, %Ecto.Changeset{}}` — validation failure
  - `{:error, term()}` — keypair storage or root-key-minting failure
  """
  @spec self_signup(map()) ::
          {:ok, %{tenant: Tenant.t(), raw_key: String.t()}}
          | {:error, :slug_taken}
          | {:error, :email_taken}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def self_signup(attrs) when is_map(attrs) do
    # US-26.7.1 (#9) — lexical keypair + deterministic secret name (see do_signup/2).
    {pub, priv} = generate_ed25519_keypair()
    secret_name = signup_secret_name(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:tenant, Tenant.self_signup_changeset(attrs))
      |> append_keypair_and_genesis(
        secret_name,
        priv,
        pub,
        "agent",
        "agent:self-signup",
        &self_signup_new_state/2
      )
      |> Multi.run(:root_api_key, fn _repo, %{activate: tenant} ->
        Auth.generate_api_key(%{
          tenant_id: tenant.id,
          name: "root",
          role: :user,
          agent_id: nil
        })
      end)

    result =
      with_secret_compensation({:delete, secret_name}, :store_secret, fn ->
        AdminRepo.transaction(multi)
      end)

    case result do
      {:ok, %{activate: tenant, root_api_key: {raw_key, _api_key}}} ->
        {:ok, %{tenant: tenant, raw_key: raw_key}}

      {:error, :tenant, %Ecto.Changeset{} = changeset, _changes} ->
        signup_changeset_error(changeset)

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp self_signup_new_state(%{activate: tenant}, pub) do
    %{
      "name" => tenant.name,
      "slug" => tenant.slug,
      "email" => tenant.email,
      "trust_tier" => "agent_rooted",
      "audit_signing_public_key" => Base.encode64(pub)
    }
  end

  # US-26.7.1 — the deterministic audit-key secret name for a signup, derived
  # from the SAME normalized slug the changeset will insert. A missing/invalid
  # slug yields a placeholder name that is never written: the `:tenant` insert
  # fails (required/format) BEFORE the `:store_secret` step runs.
  defp signup_secret_name(attrs) do
    slug = Tenant.normalized_slug(attrs) || "__invalid__"
    Secrets.audit_key_secret_name(slug)
  end

  # US-26.7.1 (AC-26.7.1.4) — shared secret-write + activation + genesis audit
  # Multi steps, appended onto a Multi that has already inserted a `:tenant`
  # step. `secret_name`/`priv`/`pub` are LEXICAL (generated by the caller
  # before the Multi), so the compensation in `with_secret_compensation/3` can
  # reference them on both the tuple and raised-exception paths without a
  # process dictionary. Used by BOTH `signup/1` and `self_signup/1`.
  #
  # `:store_secret` runs AFTER `:tenant` (and, for signup, `:authenticators`)
  # so a duplicate-slug / validation failure never reaches the external write —
  # the compensation `write_step` guard keys on this step name.
  defp append_keypair_and_genesis(
         multi,
         secret_name,
         priv,
         pub,
         actor_type,
         actor_label,
         new_state_fun
       ) do
    multi
    |> Multi.run(:store_secret, fn _repo, _changes ->
      case Secrets.set(secret_name, priv) do
        :ok -> {:ok, :stored}
        {:error, reason} -> {:error, {:audit_key_storage_failed, reason}}
      end
    end)
    |> Multi.update(:set_public_key, fn %{tenant: tenant} ->
      Ecto.Changeset.change(tenant, audit_signing_public_key: pub)
    end)
    |> Multi.update(:activate, fn %{set_public_key: tenant} ->
      Tenant.activate_after_enrollment_changeset(tenant)
    end)
    |> Audit.log_in_multi(:audit_genesis, fn changes ->
      tenant = changes.activate

      %{
        tenant_id: tenant.id,
        entity_type: "tenant",
        entity_id: tenant.id,
        action: "tenant_created",
        actor_type: actor_type,
        actor_id: nil,
        actor_label: actor_label,
        new_state: new_state_fun.(changes, pub)
      }
    end)
  end

  # US-26.7.1 (AC-26.7.1.4 / review #1, #2, #9) — TRANSACTIONAL SECRET SAFETY.
  # `Secrets.set/2` is an EXTERNAL Fly.io write that `AdminRepo.transaction/1`
  # cannot roll back. `run_txn` performs the transaction; `write_step` is the
  # Multi step whose SUCCESS means the external secret was written. On failure:
  #
  #   * tuple `{:error, step, reason, changes}` — compensate ONLY when the
  #     `write_step` succeeded (its key is present in `changes`), so an upstream
  #     failure (duplicate slug, validation, authenticator) writes nothing and
  #     compensates nothing.
  #   * raised exception — the Multi discards `changes`, so we compensate
  #     defensively using the lexical `compensation`. This is safe: a
  #     duplicate-slug collision (the ONLY case where the deterministic secret
  #     name could belong to ANOTHER tenant) is ALWAYS a mapped
  #     `unique_constraint` TUPLE, never a raise, so a raise can never target a
  #     live tenant's secret.
  #
  # `compensation` is `{:delete, secret_name}` (signup/bootstrap: no prior key)
  # or `{:restore, secret_name, old_value}` (rotate: put the OLD private key
  # back so the DB's rolled-back OLD public key still verifies).
  defp with_secret_compensation(compensation, write_step, run_txn) do
    case run_txn.() do
      {:ok, _} = ok ->
        ok

      {:error, _step, _reason, changes} = error ->
        if Map.has_key?(changes, write_step), do: run_compensation(compensation)
        error
    end
  rescue
    exception ->
      run_compensation(compensation)
      reraise exception, __STACKTRACE__
  end

  defp run_compensation({:delete, secret_name}), do: delete_secret(secret_name)

  defp run_compensation({:restore, secret_name, old_value}),
    do: restore_secret(secret_name, old_value)

  defp delete_secret(secret_name) do
    case Secrets.delete(secret_name) do
      :ok -> :ok
      # Already gone — nothing to clean up (a defensive rescue-branch delete of
      # a secret that was never written lands here).
      {:error, :not_found} -> :ok
      {:error, reason} -> handle_compensation_failure(:delete, secret_name, nil, reason)
    end
  end

  defp restore_secret(_secret_name, nil) do
    # No old value to restore (the pre-rotation read failed). Nothing we can
    # auto-recover — surface it loudly rather than swallow.
    :telemetry.execute(
      [:loopctl, :secrets, :orphan_cleanup_failed],
      %{count: 1},
      %{op: :restore, secret_name: nil, reason: :old_value_unavailable}
    )

    Logger.error(
      "Cannot restore audit-key secret after a failed rotation: the old private key " <>
        "value was unavailable. Manual intervention required."
    )

    :ok
  end

  defp restore_secret(secret_name, old_value) when is_binary(old_value) do
    case Secrets.set(secret_name, old_value) do
      :ok -> :ok
      {:error, reason} -> handle_compensation_failure(:restore, secret_name, old_value, reason)
    end
  end

  # A FAILED compensating delete/restore must NEVER be swallowed: (a) emit a
  # dedicated telemetry event so monitoring can page, (b) Logger.error, and
  # (c) enqueue a durable, retryable Oban job so cleanup actually happens
  # rather than being best-effort-once.
  defp handle_compensation_failure(op, secret_name, value, reason) do
    :telemetry.execute(
      [:loopctl, :secrets, :orphan_cleanup_failed],
      %{count: 1},
      %{op: op, secret_name: secret_name, reason: reason}
    )

    Logger.error(
      "Compensating audit-key secret #{op} failed for #{secret_name}: #{inspect(reason)}. " <>
        "Enqueued a retry; a private key may be orphaned in Fly until it succeeds."
    )

    enqueue_secret_cleanup(op, secret_name, value)
    :ok
  end

  defp enqueue_secret_cleanup(:delete, secret_name, _value) do
    %{"op" => "delete", "secret_name" => secret_name}
    |> OrphanedSecretCleanupWorker.new()
    |> Oban.insert()
  end

  defp enqueue_secret_cleanup(:restore, secret_name, value) do
    %{
      "op" => "restore",
      "secret_name" => secret_name,
      "value" => OrphanedSecretCleanupWorker.encode_secret_value(value)
    }
    |> OrphanedSecretCleanupWorker.new()
    |> Oban.insert()
  end

  defp insert_authenticators(multi, authenticators) do
    authenticators
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {entry, index}, acc ->
      Multi.run(acc, {:authenticator, index}, fn _repo, %{tenant: tenant} ->
        attestation = Map.fetch!(entry, :attestation_result)
        friendly_name = Map.get(entry, :friendly_name) || default_friendly_name(index)

        attrs =
          attestation
          |> Map.put(:friendly_name, friendly_name)
          |> Map.put_new(:sign_count, 0)

        %RootAuthenticator{tenant_id: tenant.id}
        |> RootAuthenticator.create_changeset(attrs)
        |> AdminRepo.insert()
      end)
    end)
    |> Multi.run(:authenticators, fn _repo, changes ->
      result =
        changes
        |> Enum.filter(fn
          {{:authenticator, _}, _} -> true
          _ -> false
        end)
        |> Enum.sort_by(fn {{:authenticator, i}, _} -> i end)
        |> Enum.map(fn {_, auth} -> auth end)

      {:ok, result}
    end)
  end

  defp default_friendly_name(0), do: "Primary authenticator"
  defp default_friendly_name(n), do: "Backup authenticator #{n}"

  defp signup_changeset_error(changeset) do
    cond do
      has_unique_constraint_error?(changeset, :slug) ->
        {:error, :slug_taken}

      has_unique_constraint_error?(changeset, :email) ->
        {:error, :email_taken}

      true ->
        {:error, changeset}
    end
  end

  defp has_unique_constraint_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  @doc """
  Short, non-reversible label for an authenticator's `credential_id`, used in
  audit-entry `new_state`/`old_state` payloads so authenticators can be told
  apart in human-readable logs without ever persisting the raw credential id.

  Public (US-26.7.2) so BOTH the signup ceremony (`signup/1`, above) and the
  opt-in trust-tier upgrade ceremony (`Loopctl.Tenants.Enrollment`) compute
  the identical fingerprint — a single source of truth so the two ceremonies
  can't drift.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(credential_id) when is_binary(credential_id) do
    :crypto.hash(:sha256, credential_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # Generates a fresh ed25519 keypair. Returns {public_key_bytes, private_key_bytes}.
  defp generate_ed25519_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  @doc """
  Generate an initial audit signing keypair for a legacy tenant that
  doesn't have one yet. Refuses to overwrite an existing key — use
  `rotate_audit_key/2` for that.

  Returns `{:ok, updated_tenant}` or `{:error, reason}`.
  """
  @spec bootstrap_audit_key(Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def bootstrap_audit_key(tenant_id) do
    case get_tenant(tenant_id) do
      {:error, _} = err ->
        err

      {:ok, %{audit_signing_public_key: existing}} when not is_nil(existing) ->
        {:error, :key_already_exists}

      {:ok, tenant} ->
        do_bootstrap_audit_key(tenant)
    end
  end

  defp do_bootstrap_audit_key(tenant) do
    {pub, priv} = generate_ed25519_keypair()
    secret_name = Secrets.audit_key_secret_name(tenant.slug)

    multi =
      Multi.new()
      |> Multi.run(:store_secret, fn _repo, _changes ->
        case Secrets.set(secret_name, priv) do
          :ok -> {:ok, :stored}
          {:error, reason} -> {:error, {:audit_key_storage_failed, reason}}
        end
      end)
      |> Multi.update(:set_public_key, fn _ ->
        Ecto.Changeset.change(tenant, audit_signing_public_key: pub)
      end)
      |> Audit.log_in_multi(:audit_bootstrap, fn %{set_public_key: updated} ->
        %{
          tenant_id: updated.id,
          entity_type: "tenant",
          entity_id: updated.id,
          action: "audit_key_bootstrapped",
          actor_type: "superadmin",
          actor_id: nil,
          actor_label: "superadmin:bootstrap",
          new_state: %{
            "audit_signing_public_key" => Base.encode64(pub),
            "reason" => "Legacy tenant — no key existed prior to Chain of Custody v2"
          }
        }
      end)

    # US-26.7.1 (#2) — bootstrap means NO prior key existed, so a post-`:store_secret`
    # failure compensates by DELETING the just-written secret (same machinery as
    # signup). `write_step: :store_secret` (the first step here) so the guard is
    # only satisfied once the external write actually happened.
    result =
      with_secret_compensation({:delete, secret_name}, :store_secret, fn ->
        AdminRepo.transaction(multi)
      end)

    case result do
      {:ok, %{set_public_key: tenant}} -> {:ok, tenant}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Rotate the tenant's audit signing key. Requires a WebAuthn assertion
  to authorize. Stores the old public key in `tenant_audit_key_history`,
  generates a new keypair, updates the Fly secret, and writes an audit
  chain entry.

  Returns `{:ok, updated_tenant}` or `{:error, reason}`.
  """
  @spec rotate_audit_key(Ecto.UUID.t(), binary()) :: {:ok, Tenant.t()} | {:error, term()}
  def rotate_audit_key(tenant_id, webauthn_assertion_signature) do
    case get_tenant(tenant_id) do
      {:error, _} = err ->
        err

      {:ok, tenant} ->
        old_public_key = tenant.audit_signing_public_key

        if is_nil(old_public_key) do
          {:error, :no_existing_key}
        else
          do_rotate_audit_key(tenant, old_public_key, webauthn_assertion_signature)
        end
    end
  end

  defp do_rotate_audit_key(tenant, old_public_key, webauthn_assertion_signature) do
    now = DateTime.utc_now()
    {new_pub, new_priv} = generate_ed25519_keypair()
    secret_name = Secrets.audit_key_secret_name(tenant.slug)

    # US-26.7.1 (#2) — RESTORE semantics. Rotation OVERWRITES the same
    # deterministic secret name with the NEW private key. If a step AFTER the
    # write fails, the DB rolls back to the OLD public key while Fly holds the
    # NEW private key = silent signature-verification breakage. So read the OLD
    # private value BEFORE the Multi and, on any post-write failure, RESTORE it
    # (not delete). `nil` when the old value can't be read (edge) — restore_secret/2
    # surfaces that loudly rather than deleting and losing signing entirely.
    old_priv =
      case Secrets.get(secret_name) do
        {:ok, value} -> value
        {:error, _reason} -> nil
      end

    multi =
      Multi.new()
      |> Multi.insert(:archive_old_key, fn _ ->
        %AuditKeyHistory{tenant_id: tenant.id}
        |> AuditKeyHistory.changeset(%{
          public_key: old_public_key,
          rotated_in: tenant.audit_key_rotated_at || tenant.inserted_at,
          rotated_out: now,
          rotation_signature: webauthn_assertion_signature
        })
      end)
      |> Multi.run(:store_new_secret, fn _repo, _changes ->
        case Secrets.set(secret_name, new_priv) do
          :ok -> {:ok, :stored}
          {:error, reason} -> {:error, {:audit_key_storage_failed, reason}}
        end
      end)
      |> Multi.update(:update_tenant, fn _ ->
        Ecto.Changeset.change(tenant,
          audit_signing_public_key: new_pub,
          audit_key_rotated_at: now
        )
      end)
      |> Audit.log_in_multi(:audit_rotation, fn %{update_tenant: updated_tenant} ->
        %{
          tenant_id: updated_tenant.id,
          entity_type: "tenant",
          entity_id: updated_tenant.id,
          action: "key_rotated",
          actor_type: "human",
          actor_id: nil,
          actor_label: "human:webauthn",
          new_state: %{
            "old_public_key" => Base.encode64(old_public_key),
            "new_public_key" => Base.encode64(new_pub)
          }
        }
      end)

    result =
      with_secret_compensation({:restore, secret_name, old_priv}, :store_new_secret, fn ->
        AdminRepo.transaction(multi)
      end)

    case result do
      {:ok, %{update_tenant: updated_tenant}} ->
        TenantKeys.invalidate(tenant.id)
        # US-33.3: the cached api_key snapshots carry the tenant's
        # audit_signing_public_key — bust them so a rotation is reflected at once.
        Auth.invalidate_tenant_key_cache(tenant.id)
        {:ok, updated_tenant}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the TTL (in seconds) that the pending-enrollment cleanup
  worker uses to expire half-finished signup attempts.
  """
  @spec pending_enrollment_ttl_seconds() :: pos_integer()
  def pending_enrollment_ttl_seconds, do: @pending_enrollment_ttl_seconds

  @doc """
  Maximum number of authenticators that can be enrolled in the initial
  signup ceremony.
  """
  @spec max_authenticators_per_signup() :: pos_integer()
  def max_authenticators_per_signup, do: @max_authenticators_per_signup

  @doc """
  Gets a tenant by ID.

  Returns `{:ok, tenant}` or `{:error, :not_found}`.
  """
  @spec get_tenant(Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant(id) do
    case AdminRepo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc """
  Registers (or rotates) the tenant's LCP-1 §9.2 owner key — the root of the
  custody-attestation chain. `pubkey` is the raw 32-byte ed25519 public key (the
  private half stays with the OWNER, never the server). Human-anchored + `:user`
  role at the controller. Returns `{:ok, tenant}` or `{:error, changeset}`.
  """
  @spec register_custody_owner_key(Ecto.UUID.t(), binary(), String.t(), keyword()) ::
          {:ok, Tenant.t()} | {:error, :not_found | Ecto.Changeset.t() | term()}
  def register_custody_owner_key(tenant_id, pubkey, alg \\ "ed25519", opts \\ []) do
    with {:ok, tenant} <- get_tenant(tenant_id) do
      do_register_custody_owner_key(tenant, pubkey, alg, opts)
    end
  end

  # Registers or ROTATES the owner key ATOMICALLY, recording BOTH:
  #
  #   * a `custody_owner_key_registered` entry on the hash-chained, STH-covered
  #     AuditChain — establishing/rotating the ROOT of the custody-attestation chain
  #     is the most security-critical enrollment of all, so it must be as
  #     tamper-evident and transparently enumerable as agent-key enrollment
  #     (§9.1.1). Without this, a compromised `:user` key could re-root trust with
  #     zero chain evidence.
  #
  #   * on a ROTATION (an owner key already existed), the retiring key in
  #     `tenant_custody_owner_key_history` with its `[rotated_in, rotated_out)`
  #     validity window — so ROOT attestations signed under the old key remain
  #     offline-verifiable after the rotation (§9.2), the analogue of
  #     `tenant_audit_key_history`.
  #
  # Concurrency + authorization + idempotency (review round-2):
  #
  #   * the tenant row is SELECT ... FOR UPDATE locked at the top of the Multi so two
  #     concurrent rotations serialize instead of both reading the same old key and
  #     last-write-wins silently discarding one new key + duplicating history;
  #   * a ROTATION (a DIFFERENT key already exists) REQUIRES a `:rotation_proof`
  #     signature by the OUTGOING owner key — a stolen `:user` API key alone cannot
  #     re-root trust; first registration stays authorized by the user + human-anchor
  #     controller gate;
  #   * re-submitting the SAME key is IDEMPOTENT — no history row, no `rotated` audit
  #     entry — so a network-timeout retry cannot forge a phantom rotation in the
  #     tamper-evident log.
  defp do_register_custody_owner_key(tenant, pubkey, alg, opts) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:lock_tenant, fn repo, _ -> lock_tenant_for_update(repo, tenant.id) end)
    |> Multi.run(:register, fn repo, %{lock_tenant: locked} ->
      register_or_rotate_owner_key(repo, locked, pubkey, alg, now, opts)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{register: updated}} -> {:ok, updated}
      {:error, _step, %Ecto.Changeset{} = changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp lock_tenant_for_update(repo, tenant_id) do
    import Ecto.Query

    case repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  # Decides register / rotate / idempotent-noop against the AUTHORITATIVE (post-lock)
  # tenant row. Returns `{:ok, tenant}` or `{:error, reason | changeset}`.
  defp register_or_rotate_owner_key(repo, tenant, pubkey, alg, now, opts) do
    actor_lineage = Keyword.get(opts, :actor_lineage, [])
    old_pubkey = tenant.custody_owner_pubkey
    old_alg = tenant.custody_owner_alg
    old_set_at = tenant.custody_owner_key_set_at || tenant.inserted_at

    cond do
      # Idempotent re-registration of the identical key: change nothing, forge no
      # rotation event.
      is_binary(old_pubkey) and old_pubkey == pubkey and old_alg == alg ->
        {:ok, tenant}

      # Rotation to a DIFFERENT key: require proof of possession of the outgoing root
      # private half before re-rooting the chain.
      is_binary(old_pubkey) ->
        prev = %{pubkey: old_pubkey, alg: old_alg, set_at: old_set_at}

        with :ok <- verify_owner_rotation_proof(tenant.id, prev, pubkey, alg, opts) do
          write_owner_key(repo, tenant, {pubkey, alg}, prev, actor_lineage, now)
        end

      # First registration: authorized by the user + human-anchor controller gate.
      true ->
        write_owner_key(repo, tenant, {pubkey, alg}, nil, actor_lineage, now)
    end
  end

  # A rotation must prove possession of the OUTGOING owner private key — a signature
  # over `owner_rotation_preimage(tenant_id, new_pubkey, new_alg)` verified against
  # the retiring public key. This is the §9.2 root-of-trust guard: neither a stolen
  # `:user` API key nor the operator (who never holds the owner private half) can
  # forge it.
  defp verify_owner_rotation_proof(tenant_id, prev, new_pubkey, new_alg, opts) do
    %{pubkey: old_pubkey, alg: old_alg, set_at: old_set_at} = prev

    case Keyword.get(opts, :rotation_proof) do
      sig when is_binary(sig) ->
        # Bind the OUTGOING key + its set_at so a captured proof cannot be replayed
        # after a rotate-back (see owner_rotation_preimage/5).
        preimage =
          SignedProfile.owner_rotation_preimage(
            tenant_id,
            old_pubkey,
            # MICROSECOND precision so two rotations in the same second still bind
            # distinct freshness values (the column is :utc_datetime_usec).
            DateTime.to_unix(old_set_at, :microsecond),
            new_pubkey,
            new_alg
          )

        if SignedProfile.verify(old_alg, preimage, sig, old_pubkey),
          do: :ok,
          else: {:error, :owner_rotation_proof_invalid}

      _ ->
        {:error, :owner_rotation_proof_required}
    end
  end

  # `prev` is `nil` on first registration, or `%{pubkey:, alg:, set_at:}` of the
  # retiring key on a rotation. Archives the retiring key, writes the new one, and
  # records ONE `custody_owner_key_registered` audit entry (`rotated` = prev != nil).
  defp write_owner_key(repo, tenant, {pubkey, alg}, prev, actor_lineage, now) do
    old_pubkey = prev && prev.pubkey

    with {:ok, _archived} <- maybe_archive_prev_owner_key(repo, tenant, prev, now),
         {:ok, updated} <-
           tenant
           |> Tenant.custody_owner_key_changeset(pubkey, alg)
           |> Ecto.Changeset.put_change(:custody_owner_key_set_at, now)
           |> repo.update(),
         {:ok, _entry} <-
           AuditChain.append(updated.id, %{
             action: "custody_owner_key_registered",
             actor_lineage: actor_lineage,
             entity_type: "tenant",
             entity_id: updated.id,
             payload: %{
               "owner_pubkey" => Base.encode16(pubkey, case: :lower),
               "alg" => alg,
               "rotated" => not is_nil(prev),
               "previous_owner_pubkey" => old_pubkey && Base.encode16(old_pubkey, case: :lower)
             }
           }) do
      {:ok, updated}
    end
  end

  defp maybe_archive_prev_owner_key(_repo, _tenant, nil, _now), do: {:ok, :no_prev}

  defp maybe_archive_prev_owner_key(
         repo,
         tenant,
         %{pubkey: pubkey, alg: alg, set_at: set_at},
         now
       ) do
    %CustodyOwnerKeyHistory{tenant_id: tenant.id}
    |> CustodyOwnerKeyHistory.changeset(%{
      public_key: pubkey,
      alg: alg,
      rotated_in: set_at,
      rotated_out: now
    })
    |> repo.insert()
  end

  @doc """
  Returns the tenant's owner key as `{pubkey_bytes, alg}` or `:none`.
  """
  @spec custody_owner_key(Ecto.UUID.t()) :: {binary(), String.t()} | :none
  def custody_owner_key(tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, %{custody_owner_pubkey: pk, custody_owner_alg: alg}} when is_binary(pk) ->
        {pk, alg}

      _ ->
        :none
    end
  end

  @doc """
  Counts all tenants (global, not RLS-scoped).

  Used by the US-27.15 metrics cardinality gate: the `tenant_id` label is allowed on
  the scale counters only while this stays at or below the documented cap
  (`:metrics_tenant_label_cap`). Read by the `telemetry_poller` periodic measurement,
  NOT on the per-emit hot path (the gate boolean is cached in `:persistent_term`).
  """
  @spec count() :: non_neg_integer()
  def count do
    AdminRepo.aggregate(Tenant, :count)
  end

  @doc """
  Gets a tenant by slug.

  Returns `{:ok, tenant}` or `{:error, :not_found}`.
  """
  @spec get_tenant_by_slug(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_slug(slug) do
    case AdminRepo.get_by(Tenant, slug: slug) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc "Halts a tenant's custody operations due to witness divergence."
  @spec halt_custody(Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def halt_custody(tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        tenant
        |> Ecto.Changeset.change(custody_halted_at: DateTime.utc_now())
        |> AdminRepo.update()
        |> bust_key_cache_on_update()

      error ->
        error
    end
  end

  @doc "Clears a custody halt (break-glass operation)."
  @spec clear_custody_halt(Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def clear_custody_halt(tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        tenant
        |> Ecto.Changeset.change(custody_halted_at: nil)
        |> AdminRepo.update()
        |> bust_key_cache_on_update()

      error ->
        error
    end
  end

  @doc "Returns true if tenant's custody operations are halted."
  @spec custody_halted?(Tenant.t()) :: boolean()
  def custody_halted?(%Tenant{custody_halted_at: nil}), do: false
  def custody_halted?(%Tenant{}), do: true

  @doc """
  Updates a tenant with the given attributes.

  When `settings` is provided in attrs, it is merged into the existing
  settings map (provided keys override, unspecified keys preserved).
  """
  @spec update_tenant(Tenant.t(), map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant(%Tenant{} = tenant, attrs) do
    warn_on_slug_mutation_attempt(tenant, attrs)
    attrs = merge_settings(tenant, attrs)

    tenant
    |> Tenant.update_changeset(attrs)
    |> AdminRepo.update()
    |> bust_key_cache_on_update()
  end

  @doc """
  Lists all tenants. Intended for superadmin use.

  Accepts optional filters:
  - `:status` — filter by tenant status
  """
  @spec list_tenants(keyword()) :: {:ok, [Tenant.t()]}
  def list_tenants(opts \\ []) do
    import Ecto.Query

    query =
      Tenant
      |> apply_status_filter(opts[:status])
      |> order_by([t], asc: t.name)

    {:ok, AdminRepo.all(query)}
  end

  @doc """
  Suspends a tenant by setting its status to `:suspended`.
  """
  @spec suspend_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def suspend_tenant(%Tenant{} = tenant) do
    tenant
    |> Tenant.status_changeset(:suspended)
    |> AdminRepo.update()
    |> bust_key_cache_on_update()
  end

  @doc """
  Activates a tenant by setting its status to `:active`.
  """
  @spec activate_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def activate_tenant(%Tenant{} = tenant) do
    tenant
    |> Tenant.status_changeset(:active)
    |> AdminRepo.update()
    |> bust_key_cache_on_update()
  end

  @doc """
  Gets a specific setting value from a tenant's settings map.

  Falls back to `default` if the key is not present.

  ## Examples

      iex> get_tenant_settings(tenant, "max_projects", 50)
      10  # if tenant.settings has "max_projects" => 10

      iex> get_tenant_settings(tenant, "nonexistent", 42)
      42  # fallback default
  """
  @spec get_tenant_settings(Tenant.t(), String.t(), term()) :: term()
  def get_tenant_settings(%Tenant{settings: settings}, key, default \\ nil) do
    Map.get(settings || %{}, key, default)
  end

  # --- Superadmin functions ---

  @doc """
  Lists all tenants with summary stats for superadmin use.

  Returns paginated results with project_count, story_count, agent_count,
  and api_key_count computed via subqueries.

  ## Options

  - `:status` — filter by tenant status atom
  - `:search` — case-insensitive partial match on name or slug
  - `:page` — page number (default 1)
  - `:page_size` — items per page (default 20, max 100)
  """
  @spec list_tenants_admin(keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_tenants_admin(opts \\ []) do
    import Ecto.Query

    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Tenant
      |> apply_status_filter(opts[:status])
      |> apply_search_filter(opts[:search])

    total = AdminRepo.aggregate(base_query, :count, :id)

    tenants =
      base_query
      |> order_by([t], asc: t.name)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    data = Enum.map(tenants, &tenant_with_stats/1)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a single tenant with full detail stats for superadmin use.

  Returns tenant with project_count, story_count, epic_count, agent_count,
  and api_key_count.
  """
  @spec get_tenant_admin(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_tenant_admin(id) do
    case AdminRepo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant_with_stats(tenant)}
    end
  end

  @doc """
  Updates a tenant with partial settings merge for superadmin use.

  When `settings` is provided in attrs, it is merged into the existing
  settings map (provided keys override, unspecified keys preserved).
  """
  @spec update_tenant_admin(Tenant.t(), map()) ::
          {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant_admin(%Tenant{} = tenant, attrs) do
    warn_on_slug_mutation_attempt(tenant, attrs)
    attrs = merge_settings(tenant, attrs)

    tenant
    |> Tenant.update_changeset(attrs)
    |> AdminRepo.update()
    |> bust_key_cache_on_update()
  end

  @doc """
  Returns system-wide aggregate statistics across all tenants.

  Used by the GET /api/v1/admin/stats endpoint.

  ## Returns

  A map with total counts, tenant status breakdown, story status
  aggregates, and active agent/story counts.
  """
  @spec system_stats() :: {:ok, map()}
  def system_stats do
    import Ecto.Query

    # Tenant counts by status
    tenant_stats =
      from(t in Tenant,
        select: %{
          total: count(t.id),
          active: count(fragment("CASE WHEN ? = 'active' THEN 1 END", t.status)),
          pending_enrollment:
            count(fragment("CASE WHEN ? = 'pending_enrollment' THEN 1 END", t.status)),
          suspended: count(fragment("CASE WHEN ? = 'suspended' THEN 1 END", t.status)),
          deactivated: count(fragment("CASE WHEN ? = 'deactivated' THEN 1 END", t.status))
        }
      )
      |> AdminRepo.one()

    alias Loopctl.Agents.Agent
    alias Loopctl.Auth.ApiKey
    alias Loopctl.Projects.Project
    alias Loopctl.WorkBreakdown.Epic
    alias Loopctl.WorkBreakdown.Story

    # Simple counts
    total_projects = AdminRepo.aggregate(Project, :count, :id)
    total_epics = AdminRepo.aggregate(Epic, :count, :id)
    total_stories = AdminRepo.aggregate(Story, :count, :id)
    total_agents = AdminRepo.aggregate(Agent, :count, :id)
    total_api_keys = count_active_api_keys()

    # Story status breakdowns
    stories_by_agent_status = count_stories_by_field(:agent_status)
    stories_by_verified_status = count_stories_by_field(:verified_status)

    # Active stories = implementing
    active_stories = Map.get(stories_by_agent_status, "implementing", 0)

    # Active agents = active status + last_seen_at within 24 hours
    active_agents = count_active_agents()

    {:ok,
     %{
       total_tenants: tenant_stats.total,
       tenants_active: tenant_stats.active,
       tenants_suspended: tenant_stats.suspended,
       tenants_deactivated: tenant_stats.deactivated,
       total_projects: total_projects,
       total_epics: total_epics,
       total_stories: total_stories,
       total_agents: total_agents,
       total_api_keys: total_api_keys,
       stories_by_agent_status: stories_by_agent_status,
       stories_by_verified_status: stories_by_verified_status,
       active_stories: active_stories,
       active_agents: active_agents
     }}
  end

  @doc """
  Lists audit log entries across all tenants for superadmin use.

  Joins with tenants to include tenant name/slug in each entry.
  Supports all standard audit filters plus tenant_id filter.

  ## Options

  - `:tenant_id` — filter by specific tenant
  - `:entity_type` — filter by entity type
  - `:entity_id` — filter by entity ID
  - `:action` — filter by action
  - `:actor_type` — filter by actor type
  - `:actor_id` — filter by actor ID
  - `:from` — filter entries after this DateTime
  - `:to` — filter entries before this DateTime
  - `:page` — page number (default 1)
  - `:page_size` — entries per page (default 20, max 100)
  """
  @spec list_audit_admin(keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_audit_admin(opts \\ []) do
    import Ecto.Query

    alias Loopctl.Audit.AuditLog

    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      from(a in AuditLog,
        as: :audit,
        left_join: t in Tenant,
        as: :tenant,
        on: a.tenant_id == t.id
      )
      |> apply_audit_filters(opts)

    total = AdminRepo.aggregate(base_query, :count)

    entries =
      base_query
      |> order_by([audit: a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> select([audit: a, tenant: t], %{
        id: a.id,
        tenant_id: a.tenant_id,
        tenant_name: t.name,
        tenant_slug: t.slug,
        entity_type: a.entity_type,
        entity_id: a.entity_id,
        action: a.action,
        actor_type: a.actor_type,
        actor_id: a.actor_id,
        actor_label: a.actor_label,
        old_state: a.old_state,
        new_state: a.new_state,
        project_id: a.project_id,
        metadata: a.metadata,
        inserted_at: a.inserted_at
      })
      |> AdminRepo.all()

    {:ok, %{data: entries, total: total, page: page, page_size: page_size}}
  end

  # --- Private helpers ---

  defp apply_status_filter(query, nil), do: query

  defp apply_status_filter(query, status) do
    import Ecto.Query
    where(query, [t], t.status == ^status)
  end

  defp apply_search_filter(query, nil), do: query
  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, search) do
    import Ecto.Query
    pattern = "%#{escape_like(search)}%"

    where(
      query,
      [t],
      ilike(t.name, ^pattern) or ilike(t.slug, ^pattern)
    )
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp tenant_with_stats(%Tenant{} = tenant) do
    import Ecto.Query

    alias Loopctl.Agents.Agent
    alias Loopctl.Auth.ApiKey
    alias Loopctl.Projects.Project
    alias Loopctl.WorkBreakdown.Epic
    alias Loopctl.WorkBreakdown.Story

    tid = tenant.id

    # Single query with subqueries instead of 5 individual queries
    stats =
      from(t in Tenant,
        where: t.id == ^tid,
        select: %{
          project_count:
            subquery(from(p in Project, where: p.tenant_id == ^tid, select: count(p.id))),
          story_count:
            subquery(from(s in Story, where: s.tenant_id == ^tid, select: count(s.id))),
          epic_count: subquery(from(e in Epic, where: e.tenant_id == ^tid, select: count(e.id))),
          agent_count:
            subquery(from(a in Agent, where: a.tenant_id == ^tid, select: count(a.id))),
          api_key_count:
            subquery(
              from(ak in ApiKey,
                where: ak.tenant_id == ^tid and is_nil(ak.revoked_at),
                select: count(ak.id)
              )
            )
        }
      )
      |> AdminRepo.one!()

    Map.put(stats, :tenant, tenant)
  end

  # US-33.3: the api-key cache stores each api_key WITH its :tenant preloaded, so a
  # tenant-row mutation leaves those cached snapshots stale (status,
  # custody_halted_at, trust_tier are all authorization-relevant and read off the
  # preloaded tenant by the auth pipeline). Bust the tenant's cached keys on every
  # successful tenant update so the change takes effect on the very next request
  # rather than after the TTL. A failed update is passed through untouched.
  defp bust_key_cache_on_update({:ok, %Tenant{} = tenant} = result) do
    Auth.invalidate_tenant_key_cache(tenant.id)
    result
  end

  defp bust_key_cache_on_update(other), do: other

  defp merge_settings(tenant, attrs) do
    case Map.get(attrs, "settings") || Map.get(attrs, :settings) do
      nil ->
        attrs

      new_settings when is_map(new_settings) ->
        merged = Map.merge(tenant.settings || %{}, new_settings)
        attrs |> Map.put("settings", merged) |> Map.delete(:settings)

      _ ->
        attrs
    end
  end

  # rls-02: slug is immutable on update (it keys the audit-key secret name),
  # and `update_changeset/2` silently drops any uncast `:slug`. A request that
  # nonetheless tries to rename the slug is exactly the operation that would
  # strand the audit-signing secret, so leave a forensic trail without changing
  # the ignored-and-succeeds behavior. Advisory GHSA-v62j-7vgr-rfqp.
  defp warn_on_slug_mutation_attempt(%Tenant{id: id, slug: current}, attrs) do
    case Map.get(attrs, "slug") || Map.get(attrs, :slug) do
      new_slug when is_binary(new_slug) and new_slug != current ->
        Logger.warning(
          "attempted slug mutation ignored for tenant #{id} " <>
            "(#{inspect(current)} -> #{inspect(new_slug)}); slug is immutable (rls-02)"
        )

      _ ->
        :ok
    end
  end

  defp count_active_api_keys do
    import Ecto.Query

    alias Loopctl.Auth.ApiKey

    from(ak in ApiKey, where: is_nil(ak.revoked_at), select: count(ak.id))
    |> AdminRepo.one()
  end

  defp count_stories_by_field(field) do
    import Ecto.Query

    alias Loopctl.WorkBreakdown.Story

    field_atom = field

    from(s in Story,
      group_by: field(s, ^field_atom),
      select: {field(s, ^field_atom), count(s.id)}
    )
    |> AdminRepo.all()
    |> Map.new(fn {status, count} -> {to_string(status), count} end)
  end

  defp count_active_agents do
    import Ecto.Query

    alias Loopctl.Agents.Agent

    cutoff = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    from(a in Agent,
      where: a.status == :active and a.last_seen_at > ^cutoff,
      select: count(a.id)
    )
    |> AdminRepo.one()
  end

  defp apply_audit_filters(query, opts) do
    import Ecto.Query

    query
    |> audit_filter(:tenant_id, Keyword.get(opts, :tenant_id))
    |> audit_filter(:entity_type, Keyword.get(opts, :entity_type))
    |> audit_filter(:entity_id, Keyword.get(opts, :entity_id))
    |> audit_filter(:action, Keyword.get(opts, :action))
    |> audit_filter(:actor_type, Keyword.get(opts, :actor_type))
    |> audit_filter(:actor_id, Keyword.get(opts, :actor_id))
    |> audit_filter_from(Keyword.get(opts, :from))
    |> audit_filter_to(Keyword.get(opts, :to))
  end

  defp audit_filter(query, _field, nil), do: query
  defp audit_filter(query, _field, ""), do: query

  defp audit_filter(query, :tenant_id, val) do
    import Ecto.Query
    where(query, [audit: a], a.tenant_id == ^val)
  end

  defp audit_filter(query, :entity_type, val) do
    import Ecto.Query
    where(query, [audit: a], a.entity_type == ^val)
  end

  defp audit_filter(query, :entity_id, val) do
    import Ecto.Query
    where(query, [audit: a], a.entity_id == ^val)
  end

  defp audit_filter(query, :action, val) do
    import Ecto.Query
    where(query, [audit: a], a.action == ^val)
  end

  defp audit_filter(query, :actor_type, val) do
    import Ecto.Query
    where(query, [audit: a], a.actor_type == ^val)
  end

  defp audit_filter(query, :actor_id, val) do
    import Ecto.Query
    where(query, [audit: a], a.actor_id == ^val)
  end

  defp audit_filter_from(query, nil), do: query

  defp audit_filter_from(query, from) do
    import Ecto.Query
    where(query, [audit: a], a.inserted_at >= ^from)
  end

  defp audit_filter_to(query, nil), do: query

  defp audit_filter_to(query, to) do
    import Ecto.Query
    where(query, [audit: a], a.inserted_at <= ^to)
  end
end
