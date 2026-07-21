defmodule Loopctl.Auth.ApiKeyTest do
  @moduledoc """
  Tests for the API-key changesets — specifically the HTTP-scoped changeset
  that structurally excludes `:superadmin` from the public create path (#462).

  Layering under test:

  - `create_changeset/2` (full role set) — the privileged bootstrap/fixture/
    dispatch path that MAY still mint a `:superadmin` key.
  - `http_create_changeset/2` (allowlist minus superadmin) — the public HTTP
    path backstop that refuses to mint a `:superadmin` key.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey

  describe "http_roles/0" do
    test "excludes :superadmin from the HTTP-creatable role set" do
      refute :superadmin in ApiKey.http_roles()
      assert Enum.sort(ApiKey.http_roles()) == Enum.sort([:user, :orchestrator, :agent])
      # And the full set still carries superadmin for the privileged path.
      assert :superadmin in ApiKey.roles()
    end
  end

  describe "http_create_changeset/2" do
    test "rejects role :superadmin with a clear error" do
      changeset =
        ApiKey.http_create_changeset(%ApiKey{}, %{name: "hacker", role: :superadmin})

      refute changeset.valid?

      assert "superadmin keys cannot be created via the API" in errors_on(changeset).role
    end

    for role <- [:user, :orchestrator, :agent] do
      test "accepts role #{inspect(role)} (tenant-scoped)" do
        tenant = fixture(:tenant)

        changeset =
          %ApiKey{tenant_id: tenant.id}
          |> ApiKey.http_create_changeset(%{name: "k", role: unquote(role)})

        assert changeset.valid?
        assert Ecto.Changeset.get_field(changeset, :role) == unquote(role)
      end
    end

    test "a non-superadmin invalid role gets a generic error, not the superadmin message" do
      tenant = fixture(:tenant)

      changeset =
        %ApiKey{tenant_id: tenant.id}
        |> ApiKey.http_create_changeset(%{name: "k", role: :wizard})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).role
      refute "superadmin keys cannot be created via the API" in errors_on(changeset).role
    end

    test "still enforces tenant_id for non-superadmin roles" do
      changeset = ApiKey.http_create_changeset(%ApiKey{}, %{name: "k", role: :user})

      refute changeset.valid?
      assert errors_on(changeset).tenant_id != []
    end
  end

  describe "create_changeset/2 (privileged full-role path)" do
    test "still accepts role :superadmin (with nil tenant_id)" do
      changeset = ApiKey.create_changeset(%ApiKey{}, %{name: "root", role: :superadmin})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :role) == :superadmin
    end
  end

  describe "Auth.generate_api_key/2 with changeset: :http" do
    test "rejects role :superadmin with a clear error" do
      assert {:error, changeset} =
               Auth.generate_api_key(%{name: "hacker", role: :superadmin}, changeset: :http)

      assert "superadmin keys cannot be created via the API" in errors_on(changeset).role
    end

    for role <- [:user, :orchestrator, :agent] do
      test "creates a #{inspect(role)} key" do
        tenant = fixture(:tenant)

        assert {:ok, {raw_key, %ApiKey{} = api_key}} =
                 Auth.generate_api_key(
                   %{tenant_id: tenant.id, name: "k", role: unquote(role)},
                   changeset: :http
                 )

        assert String.starts_with?(raw_key, "lc_")
        assert api_key.role == unquote(role)
        assert api_key.tenant_id == tenant.id
      end
    end
  end

  describe "Auth.generate_api_key/1 (default full changeset) — regression" do
    test "privileged superadmin provisioning path is unaffected" do
      assert {:ok, {_raw, %ApiKey{} = api_key}} =
               Auth.generate_api_key(%{name: "root", role: :superadmin})

      assert api_key.role == :superadmin
      assert api_key.tenant_id == nil
    end
  end

  describe "tenant isolation" do
    test "HTTP-created keys are scoped to their own tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      assert {:ok, {_raw_a, key_a}} =
               Auth.generate_api_key(
                 %{tenant_id: tenant_a.id, name: "key-a", role: :agent},
                 changeset: :http
               )

      assert {:ok, {_raw_b, key_b}} =
               Auth.generate_api_key(
                 %{tenant_id: tenant_b.id, name: "key-b", role: :agent},
                 changeset: :http
               )

      assert key_a.tenant_id == tenant_a.id
      assert key_b.tenant_id == tenant_b.id

      assert {:ok, keys_a} = Auth.list_api_keys(tenant_a.id)
      assert Enum.map(keys_a, & &1.name) == ["key-a"]

      assert {:ok, keys_b} = Auth.list_api_keys(tenant_b.id)
      assert Enum.map(keys_b, & &1.name) == ["key-b"]
    end
  end
end
