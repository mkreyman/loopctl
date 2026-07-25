defmodule Loopctl.Tenants.SignupTest do
  @moduledoc """
  US-26.0.1 — context-level coverage for the tenant signup ceremony.

  Mocks the WebAuthn adapter via `Loopctl.MockWebAuthn` (swapped in via
  `config/test.exs`). Every test must be async-safe and use fixtures
  from `test/support/fixtures.ex`.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Secrets
  alias Loopctl.Tenants
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.OrphanedSecretCleanupWorker
  alias Loopctl.Workers.PendingEnrollmentCleanupWorker

  setup :verify_on_exit!

  defp valid_attestation(friendly \\ "Primary YubiKey") do
    %{
      attestation_result: %{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: :crypto.strong_rand_bytes(64),
        attestation_format: "none",
        sign_count: 0
      },
      friendly_name: friendly
    }
  end

  describe "signup/1" do
    test "creates tenant + root authenticator + audit entry (TC-26.0.1.1)" do
      attrs = %{
        name: "Test Signup",
        slug: "test-signup",
        email: "admin@test-signup.example",
        authenticators: [valid_attestation()]
      }

      assert {:ok, %{tenant: tenant, root_authenticators: [auth], raw_key: raw_key}} =
               Tenants.signup(attrs)

      assert tenant.status == :active
      assert tenant.slug == "test-signup"
      assert tenant.email == "admin@test-signup.example"
      assert auth.tenant_id == tenant.id
      assert auth.friendly_name == "Primary YubiKey"
      assert auth.attestation_format == "none"

      # #500: signup mints a usable root user-role key and returns it ONCE, so a
      # browser-onboarded tenant has an authenticated path forward (was: empty api_keys).
      assert is_binary(raw_key) and raw_key != ""
      assert {:ok, verified} = Auth.verify_api_key(raw_key)
      assert verified.tenant_id == tenant.id
      assert verified.role == :user
      assert is_nil(verified.agent_id)

      # Idempotent persistence: re-reading surfaces the same row.
      [persisted] = RootAuthenticators.list_by_tenant(tenant.id)
      assert persisted.id == auth.id

      # inserted_at is within the last 60 seconds.
      age = DateTime.diff(DateTime.utc_now(), tenant.inserted_at, :second)
      assert age >= 0 and age < 60
    end

    test "empty authenticator list returns :no_authenticators" do
      attrs = %{
        name: "Empty",
        slug: "empty-signup",
        email: "empty@example.com",
        authenticators: []
      }

      assert {:error, :no_authenticators} = Tenants.signup(attrs)
      assert {:error, :not_found} = Tenants.get_tenant_by_slug("empty-signup")
    end

    test "more than 5 authenticators rejected" do
      attrs = %{
        name: "Too Many",
        slug: "too-many",
        email: "toomany@example.com",
        authenticators: Enum.map(1..6, fn i -> valid_attestation("key-#{i}") end)
      }

      assert {:error, :too_many_authenticators} = Tenants.signup(attrs)
      assert {:error, :not_found} = Tenants.get_tenant_by_slug("too-many")
    end

    test "duplicate slug returns :slug_taken (TC-26.0.1.3)" do
      fixture(:tenant, %{slug: "taken"})

      attrs = %{
        name: "Other",
        slug: "taken",
        email: "other@example.com",
        authenticators: [valid_attestation()]
      }

      assert {:error, :slug_taken} = Tenants.signup(attrs)
    end

    test "duplicate email returns :email_taken" do
      fixture(:tenant, %{email: "same@example.com"})

      attrs = %{
        name: "Other",
        slug: "other-slug",
        email: "same@example.com",
        authenticators: [valid_attestation()]
      }

      assert {:error, :email_taken} = Tenants.signup(attrs)
    end

    test "invalid slug format is rejected with a changeset" do
      attrs = %{
        name: "Weird",
        slug: "NOT A SLUG",
        email: "weird@example.com",
        authenticators: [valid_attestation()]
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Tenants.signup(attrs)
      assert %{slug: _} = errors_on(changeset)
    end

    test "two authenticators in a single ceremony (TC-26.0.1.4)" do
      attrs = %{
        name: "Multi Key",
        slug: "multi-key",
        email: "multi@example.com",
        authenticators: [
          valid_attestation("Primary YubiKey"),
          valid_attestation("Backup Touch ID")
        ]
      }

      assert {:ok, %{tenant: tenant, root_authenticators: auths}} = Tenants.signup(attrs)
      assert length(auths) == 2
      assert Enum.all?(auths, &(&1.tenant_id == tenant.id))
      assert RootAuthenticators.count_by_tenant(tenant.id) == 2
    end

    test "slug is normalized to lowercase during signup" do
      attrs = %{
        name: "Casing",
        slug: "CASING-OK",
        email: "Admin@Example.COM",
        authenticators: [valid_attestation()]
      }

      assert {:ok, %{tenant: tenant}} = Tenants.signup(attrs)
      assert tenant.slug == "casing-ok"
      assert tenant.email == "admin@example.com"
    end

    # AC-26.7.1.2 — the custody-operations half of this claim is proven by
    # LoopctlWeb.Plugs.RequireHumanAnchorTest ("passes through for a
    # human_anchored tenant") plus the fixture default (fixture(:tenant) is
    # :human_anchored) leaving the entire pre-existing custody-controller
    # test suite unaffected — TC-26.7.1.5.
    test "a WebAuthn-signed tenant is human_anchored" do
      attrs = %{
        name: "Human Anchored",
        slug: "human-anchored-#{System.unique_integer([:positive])}",
        email: "human-anchored-#{System.unique_integer([:positive])}@example.com",
        authenticators: [valid_attestation()]
      }

      assert {:ok, %{tenant: tenant}} = Tenants.signup(attrs)
      assert tenant.trust_tier == :human_anchored

      # Re-read to prove persistence, not just the in-memory struct.
      {:ok, persisted} = Tenants.get_tenant(tenant.id)
      assert persisted.trust_tier == :human_anchored

      # Genesis audit entry carries the human actor.
      import Ecto.Query
      alias Loopctl.Audit.AuditLog

      entry =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "tenant_created")
        |> AdminRepo.one!()

      assert entry.actor_type == "human"
      assert entry.actor_label == "human:webauthn"
    end

    test "tenant A's root authenticators are invisible to tenant B (isolation)" do
      {:ok, %{tenant: tenant_a}} =
        Tenants.signup(%{
          name: "Tenant A",
          slug: "tenant-a-iso",
          email: "a@iso.example",
          authenticators: [valid_attestation()]
        })

      {:ok, %{tenant: tenant_b}} =
        Tenants.signup(%{
          name: "Tenant B",
          slug: "tenant-b-iso",
          email: "b@iso.example",
          authenticators: [valid_attestation()]
        })

      assert [_one] = RootAuthenticators.list_by_tenant(tenant_a.id)
      assert [_one] = RootAuthenticators.list_by_tenant(tenant_b.id)

      # Cross-tenant fetch must not leak.
      [auth_a] = RootAuthenticators.list_by_tenant(tenant_a.id)

      assert {:error, :not_found} =
               RootAuthenticators.get_by_credential_id(tenant_b.id, auth_a.credential_id)
    end
  end

  describe "self_signup/1 (US-26.7.1)" do
    test "creates an activated agent-rooted tenant with agent genesis and a user key (TC-26.7.1.1)" do
      unique = System.unique_integer([:positive])

      # The default MockSecrets stubs (stub_all_defaults/0) are stateless
      # (set always :ok, get always :not_found) — stub a shared, PER-TEST
      # store here so `Secrets.get/1` genuinely reflects what `Secrets.set/2`
      # wrote, proving the private key is retrievable (TC-26.7.1.1).
      Mox.stub(Loopctl.MockSecrets, :set, fn name, value ->
        Process.put({:secret, name}, value)
        :ok
      end)

      Mox.stub(Loopctl.MockSecrets, :get, fn name ->
        case Process.get({:secret, name}) do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end
      end)

      attrs = %{
        name: "Self Signup Co",
        slug: "self-signup-#{unique}",
        email: "self-signup-#{unique}@example.com"
      }

      assert {:ok, %{tenant: tenant, raw_key: raw_key}} = Tenants.self_signup(attrs)

      assert tenant.trust_tier == :agent_rooted
      assert tenant.status == :active
      assert is_binary(tenant.audit_signing_public_key)
      assert {:ok, _priv} = Secrets.get(Secrets.audit_key_secret_name(tenant.slug))

      # No authenticators are inserted for this path.
      assert RootAuthenticators.list_by_tenant(tenant.id) == []

      # Genesis audit entry: agent actor, not human.
      import Ecto.Query
      alias Loopctl.Audit.AuditLog

      entry =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "tenant_created")
        |> AdminRepo.one!()

      assert entry.actor_type == "agent"
      assert entry.actor_label == "agent:self-signup"

      # The raw_key resolves to a role:user, agent_id:nil key bound to the tenant.
      assert is_binary(raw_key)
      assert String.starts_with?(raw_key, "lc_")
      assert {:ok, api_key} = Auth.verify_api_key(raw_key)
      assert api_key.tenant_id == tenant.id
      assert api_key.role == :user
      assert api_key.agent_id == nil

      # Only the hash is stored — the raw key text never appears in the DB row.
      refute api_key.key_hash == raw_key
    end

    # Review #5 — precondition guard for the bootstrap-audit-key tier exemption:
    # BOTH signup paths mandatorily pre-provision the audit key, so a freshly
    # created tenant ALWAYS has a non-nil public key (making `bootstrap` a
    # guaranteed `key_already_exists` 409 → unreachable, hence not tier-gated).
    # If provisioning ever became lazy, this fails and flags the exemption.
    test "a freshly self-signed-up tenant always has a non-nil audit signing public key" do
      unique = System.unique_integer([:positive])

      assert {:ok, %{tenant: tenant}} =
               Tenants.self_signup(%{
                 name: "Provisioned",
                 slug: "provisioned-#{unique}",
                 email: "provisioned-#{unique}@example.com"
               })

      {:ok, reread} = Tenants.get_tenant(tenant.id)
      refute is_nil(reread.audit_signing_public_key)
    end

    test "mass assignment is closed: trust_tier/role/tenant_id/agent_id in attrs are ignored" do
      unique = System.unique_integer([:positive])

      attrs = %{
        name: "Sneaky",
        slug: "sneaky-context-#{unique}",
        email: "sneaky-context-#{unique}@example.com",
        trust_tier: :human_anchored,
        role: :superadmin,
        tenant_id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate()
      }

      assert {:ok, %{tenant: tenant}} = Tenants.self_signup(attrs)
      assert tenant.trust_tier == :agent_rooted
    end

    test "duplicate slug returns :slug_taken" do
      fixture(:tenant, %{slug: "self-signup-taken"})

      attrs = %{name: "Other", slug: "self-signup-taken", email: "other-self@example.com"}
      assert {:error, :slug_taken} = Tenants.self_signup(attrs)
    end

    test "duplicate email returns :email_taken" do
      fixture(:tenant, %{email: "self-signup-dup@example.com"})

      attrs = %{
        name: "Other",
        slug: "self-signup-other-slug",
        email: "self-signup-dup@example.com"
      }

      assert {:error, :email_taken} = Tenants.self_signup(attrs)
    end

    test "invalid slug format is rejected with a changeset" do
      attrs = %{name: "Weird", slug: "NOT A SLUG", email: "weird-self@example.com"}

      assert {:error, %Ecto.Changeset{} = changeset} = Tenants.self_signup(attrs)
      assert %{slug: _} = errors_on(changeset)
    end

    # Tenant isolation for the context layer (mirrors the RootAuthenticators
    # isolation test above; self-signup has no authenticators to isolate, so
    # this proves tenant records themselves stay isolated).
    test "tenant A and tenant B from self_signup are distinct, isolated tenants" do
      {:ok, %{tenant: tenant_a}} =
        Tenants.self_signup(%{
          name: "A",
          slug: "self-iso-a-#{System.unique_integer([:positive])}",
          email: "self-iso-a-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, %{tenant: tenant_b}} =
        Tenants.self_signup(%{
          name: "B",
          slug: "self-iso-b-#{System.unique_integer([:positive])}",
          email: "self-iso-b-#{System.unique_integer([:positive])}@example.com"
        })

      assert tenant_a.id != tenant_b.id
      assert tenant_a.trust_tier == :agent_rooted
      assert tenant_b.trust_tier == :agent_rooted
    end
  end

  describe "transactional secret compensation (AC-26.7.1.4 / TC-26.7.1.2)" do
    test "self_signup/1 deletes the external secret when a later Multi step fails" do
      slug = "compensate-self-#{System.unique_integer([:positive])}"
      test_pid = self()

      # Force a REAL failure in a step AFTER Secrets.set succeeds: delete the
      # tenant row (bypassing Ecto) from within the Secrets.set stub, so the
      # VERY NEXT step (`:set_public_key`, an `Ecto.Repo.update` against the
      # now-vanished row) raises `Ecto.StaleEntryError` — exercising the
      # rescue arm of `with_secret_compensation/3`.
      Mox.expect(Loopctl.MockSecrets, :set, fn secret_name, _priv ->
        AdminRepo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
        send(test_pid, {:secret_set, secret_name})
        :ok
      end)

      Mox.expect(Loopctl.MockSecrets, :delete, fn secret_name ->
        send(test_pid, {:secret_deleted, secret_name})
        :ok
      end)

      assert_raise Ecto.StaleEntryError, fn ->
        Tenants.self_signup(%{
          name: "Compensate Me",
          slug: slug,
          email: "compensate-self@example.com"
        })
      end

      assert_receive {:secret_set, secret_name}
      assert_receive {:secret_deleted, ^secret_name}
      assert secret_name == Secrets.audit_key_secret_name(slug)

      # Nothing left behind: no tenant, no root api_key, no audit entry.
      assert {:error, :not_found} = Tenants.get_tenant_by_slug(slug)
    end

    test "signup/1 (WebAuthn ceremony) deletes the external secret when a later Multi step fails" do
      slug = "compensate-webauthn-#{System.unique_integer([:positive])}"
      test_pid = self()

      Mox.expect(Loopctl.MockSecrets, :set, fn secret_name, _priv ->
        AdminRepo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
        send(test_pid, {:secret_set, secret_name})
        :ok
      end)

      Mox.expect(Loopctl.MockSecrets, :delete, fn secret_name ->
        send(test_pid, {:secret_deleted, secret_name})
        :ok
      end)

      assert_raise Ecto.StaleEntryError, fn ->
        Tenants.signup(%{
          name: "Compensate Me Too",
          slug: slug,
          email: "compensate-webauthn@example.com",
          authenticators: [valid_attestation()]
        })
      end

      assert_receive {:secret_set, secret_name}
      assert_receive {:secret_deleted, ^secret_name}
      assert secret_name == Secrets.audit_key_secret_name(slug)

      assert {:error, :not_found} = Tenants.get_tenant_by_slug(slug)
    end

    # Tuple branch, guard = FALSE (Map.has_key?(changes, :store_secret) is false).
    test "no compensation runs when the failure happens BEFORE Secrets.set (no secret was ever written)" do
      fixture(:tenant, %{slug: "no-compensation-needed"})

      # :delete must never be called — the changeset failure on the `:tenant`
      # insert happens BEFORE the `:store_secret` step, so with_secret_compensation/3's
      # write-step guard correctly skips compensation (nothing was written).
      Mox.expect(Loopctl.MockSecrets, :delete, 0, fn _name -> :ok end)

      assert {:error, :slug_taken} =
               Tenants.self_signup(%{
                 name: "No Secret Written",
                 slug: "no-compensation-needed",
                 email: "no-compensation@example.com"
               })
    end

    # Review #1 (HIGH) — a FAILED compensating delete must NOT be swallowed.
    test "a failed compensating delete fires telemetry AND enqueues a durable Oban retry" do
      slug = "compensate-delete-fails-#{System.unique_integer([:positive])}"
      handler = "orphan-cleanup-#{System.unique_integer([:positive])}"
      test_pid = self()

      # Same mid-Multi failure trigger as above (delete the tenant so a later
      # update raises StaleEntryError), but now the compensating delete FAILS.
      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _priv ->
        AdminRepo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
        :ok
      end)

      Mox.expect(Loopctl.MockSecrets, :delete, fn _name -> {:error, :fly_unavailable} end)

      :telemetry.attach(
        handler,
        [:loopctl, :secrets, :orphan_cleanup_failed],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # :manual so the enqueued retry is observable via assert_enqueued rather
      # than executing inline (the suite's default Oban testing mode).
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert_raise Ecto.StaleEntryError, fn ->
          Tenants.self_signup(%{
            name: "Delete Fails",
            slug: slug,
            email: "compensate-delete-fails@example.com"
          })
        end
      end)

      secret_name = Secrets.audit_key_secret_name(slug)

      assert_received {:telemetry, [:loopctl, :secrets, :orphan_cleanup_failed], %{count: 1},
                       %{op: :delete, secret_name: ^secret_name, reason: :fly_unavailable}}

      assert_enqueued(
        worker: OrphanedSecretCleanupWorker,
        args: %{"op" => "delete", "secret_name" => secret_name}
      )
    end

    # Review #3 — TUPLE-branch (clean {:error, ...}) compensation.
    #
    # NOTE (honest coverage limitation): the clean-tuple post-`:store_secret`
    # path is NOT deterministically reachable through any public flow. The only
    # tuple-returning post-write step is self_signup/1's `:root_api_key`, and
    # `Auth.generate_api_key/1` only returns `{:error, changeset}` on a
    # validation error or a MAPPED api_keys constraint — neither is trippable by
    # the valid `role: :user` root key (the mapped `[:tenant_id, :agent_id]`
    # unique index is PARTIAL, excluding user/superadmin roles). Every other
    # post-write step (`:set_public_key`, `:activate`, `:audit_genesis`) RAISES
    # on failure (covered by the rescue-branch tests above). Deleting the tenant
    # mid-Multi always trips `:set_public_key`'s StaleEntryError first.
    #
    # So this test asserts what IS observable and load-bearing: the write-step
    # GUARD. It confirms the guard=TRUE arm (store_secret present in `changes`)
    # runs `run_compensation/1` — the SAME function the (tested) rescue arm
    # calls — by driving a rollback where the secret WAS written and asserting
    # the delete fired exactly once. (guard=FALSE is the test directly above.)
    test "tuple/rescue compensation runs run_compensation exactly once when the secret was written" do
      slug = "compensate-once-#{System.unique_integer([:positive])}"
      test_pid = self()

      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _priv ->
        AdminRepo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
        :ok
      end)

      # Exactly ONE compensating delete — proves the two branches don't
      # double-compensate and that the write-step guard fired.
      Mox.expect(Loopctl.MockSecrets, :delete, 1, fn name ->
        send(test_pid, {:deleted, name})
        :ok
      end)

      assert_raise Ecto.StaleEntryError, fn ->
        Tenants.self_signup(%{
          name: "Compensate Once",
          slug: slug,
          email: "compensate-once@example.com"
        })
      end

      assert_received {:deleted, secret_name}
      assert secret_name == Secrets.audit_key_secret_name(slug)
    end
  end

  describe "PendingEnrollmentCleanupWorker (TC-26.0.1.5)" do
    test "deletes tenants stuck in :pending_enrollment past the TTL" do
      # Insert a tenant directly in :pending_enrollment state with an
      # inserted_at in the past so the worker sweeps it.
      old =
        %Tenant{}
        |> Tenant.signup_changeset(%{
          name: "Abandoned",
          slug: "abandoned-old",
          email: "abandoned@example.com"
        })
        |> AdminRepo.insert!()

      past = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      {1, _} =
        from(t in Tenant, where: t.id == ^old.id)
        |> AdminRepo.update_all(set: [inserted_at: past])

      # A fresh pending enrollment should NOT be touched.
      _fresh =
        %Tenant{}
        |> Tenant.signup_changeset(%{
          name: "Fresh",
          slug: "fresh-signup",
          email: "fresh@example.com"
        })
        |> AdminRepo.insert!()

      assert :ok = PendingEnrollmentCleanupWorker.perform(%Oban.Job{args: %{}})

      assert AdminRepo.get(Tenant, old.id) == nil
      assert AdminRepo.get_by(Tenant, slug: "fresh-signup") != nil
    end
  end

  describe "RootAuthenticators context" do
    test "cannot create a row without a tenant_id" do
      assert_raise FunctionClauseError, fn ->
        RootAuthenticators.create(nil, %{})
      end
    end

    test "rejects duplicate (tenant_id, credential_id)" do
      {:ok, %{tenant: tenant}} =
        Tenants.signup(%{
          name: "Dup",
          slug: "dup-tenant",
          email: "dup@example.com",
          authenticators: [valid_attestation()]
        })

      [auth] = RootAuthenticators.list_by_tenant(tenant.id)

      assert {:error, changeset} =
               RootAuthenticators.create(tenant.id, %{
                 credential_id: auth.credential_id,
                 public_key: auth.public_key,
                 attestation_format: auth.attestation_format,
                 friendly_name: "Dup"
               })

      assert %{credential_id: _} = errors_on(changeset)
    end
  end

  describe "Loopctl.Tenants.RootAuthenticator schema" do
    test "struct builds from %RootAuthenticator{}" do
      assert %RootAuthenticator{sign_count: 0} = %RootAuthenticator{}
    end
  end
end
