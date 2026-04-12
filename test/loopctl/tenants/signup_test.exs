defmodule Loopctl.Tenants.SignupTest do
  @moduledoc """
  US-26.0.1 — context-level coverage for the tenant signup ceremony.

  Mocks the WebAuthn adapter via `Loopctl.MockWebAuthn` (swapped in via
  `config/test.exs`). Every test must be async-safe and use fixtures
  from `test/support/fixtures.ex`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.Tenants.Tenant
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

      assert {:ok, %{tenant: tenant, root_authenticators: [auth]}} = Tenants.signup(attrs)
      assert tenant.status == :active
      assert tenant.slug == "test-signup"
      assert tenant.email == "admin@test-signup.example"
      assert auth.tenant_id == tenant.id
      assert auth.friendly_name == "Primary YubiKey"
      assert auth.attestation_format == "none"

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
