defmodule Loopctl.ForgeTest do
  @moduledoc """
  #936: a tenant's own GitHub token, and the credential every forge call resolves from it
  (`Loopctl.Verification.ForgeCredential`).
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Forge
  alias Loopctl.Forge.TenantCredential
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.ForgeCredential

  # Named with acme/widgets in `config/test.exs`'s `:verification_operator_token_tenants`.
  @allowlisted "0000a110-0000-4000-8000-00000000a110"

  describe "set_token/3, view/1, token/1" do
    test "stores the token encrypted and shows only whether it is set and its last four" do
      tenant = fixture(:tenant)

      assert {:ok, view} = Forge.set_token(tenant.id, "  github_pat_secret1234  ", nil)
      assert view.has_token
      assert view.token_hint == "…1234"
      refute inspect(view) =~ "github_pat_secret1234"

      assert Forge.token(tenant.id) == {:ok, "github_pat_secret1234"}

      [raw] =
        AdminRepo.all(
          from c in "tenant_github_credentials",
            where: c.tenant_id == type(^tenant.id, :binary_id),
            select: c.token
        )

      refute raw =~ "github_pat_secret1234"
    end

    test "replacing keeps one row and the new token" do
      tenant = fixture(:tenant)
      {:ok, _} = Forge.set_token(tenant.id, "github_pat_first00001", nil)
      {:ok, _} = Forge.set_token(tenant.id, "github_pat_second0002", nil)

      assert Forge.token(tenant.id) == {:ok, "github_pat_second0002"}

      assert AdminRepo.aggregate(
               from(c in TenantCredential, where: c.tenant_id == ^tenant.id),
               :count
             ) == 1
    end

    test "a blank, whitespace-bearing, oversized or non-string token is refused" do
      tenant = fixture(:tenant)

      for bad <- ["   ", "github pat", String.duplicate("a", 501), nil, 42] do
        assert {:error, %Ecto.Changeset{errors: [token: _]}} =
                 Forge.set_token(tenant.id, bad, nil)
      end

      assert Forge.token(tenant.id) == :none
    end

    test "setting, replacing and clearing are audited without the value" do
      tenant = fixture(:tenant)
      {:ok, _} = Forge.set_token(tenant.id, "github_pat_audited0001", nil)
      {:ok, _} = Forge.set_token(tenant.id, "github_pat_audited0002", nil)
      {:ok, _} = Forge.clear_token(tenant.id, nil)

      events =
        AdminRepo.all(
          from a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.entity_type == "github_credential",
            order_by: [asc: a.inserted_at]
        )

      assert Enum.map(events, & &1.action) == [
               "github_credential.set",
               "github_credential.replaced",
               "github_credential.cleared"
             ]

      refute inspect(events) =~ "github_pat_audited"
    end

    test "tenant isolation: one tenant's token is never another's" do
      a = fixture(:tenant)
      b = fixture(:tenant)
      {:ok, _} = Forge.set_token(a.id, "github_pat_tenant_a01", nil)

      assert Forge.token(b.id) == :none
      refute Forge.view(b.id).has_token
      assert {:ok, _} = Forge.clear_token(b.id, nil)
      assert Forge.token(a.id) == {:ok, "github_pat_tenant_a01"}
    end

    test "an id that is not a UUID has no token, and raises nothing" do
      assert Forge.token("not-a-uuid") == :none
      assert Forge.token(nil) == :none
    end
  end

  describe "ForgeCredential.for_read/2" do
    test "a tenant with its own token gets it, for any repository" do
      tenant = fixture(:tenant)
      {:ok, _} = Forge.set_token(tenant.id, "github_pat_own_000001", nil)

      assert {:ok,
              %Credential{
                kind: :tenant_token,
                repo: %ForgeRepo{
                  full_name: "anyone/anything",
                  auth: {:token, "github_pat_own_000001"}
                }
              }} = ForgeCredential.for_read(tenant.id, "anyone/anything")

      assert ForgeCredential.any_for_tenant?(tenant.id)
    end

    test "a tenant with its own token never falls back to the operator's, even for a pair the " <>
           "allowlist names" do
      # The allowlisted tenant id, given a row of its own so it can hold a token.
      tenant = fixture(:tenant)

      {1, _} =
        AdminRepo.update_all(from(t in Loopctl.Tenants.Tenant, where: t.id == ^tenant.id),
          set: [id: @allowlisted]
        )

      {:ok, _} = Forge.set_token(@allowlisted, "github_pat_allowlisted1", nil)

      assert {:ok,
              %Credential{
                kind: :tenant_token,
                repo: %ForgeRepo{auth: {:token, "github_pat_allowlisted1"}}
              }} = ForgeCredential.for_read(@allowlisted, "acme/widgets")
    end

    test "a tenant with no token and no allowlist entry gets nothing" do
      tenant = fixture(:tenant)

      assert ForgeCredential.for_read(tenant.id, "acme/widgets") ==
               {:error, :credential_unavailable}

      refute ForgeCredential.any_for_tenant?(tenant.id)
    end

    test "an allowlisted pair with no tenant token gets the operator's, and only that pair" do
      assert {:ok, %Credential{kind: :operator_token, repo: %ForgeRepo{auth: :operator}}} =
               ForgeCredential.for_read(@allowlisted, "acme/widgets")

      assert ForgeCredential.for_read(@allowlisted, "acme/other") ==
               {:error, :credential_unavailable}

      assert ForgeCredential.any_for_tenant?(@allowlisted)
    end
  end

  describe "repeated writes" do
    # Sandbox tasks share one connection, so these run one after another: this pins the
    # upsert and delete-by-tenant SHAPES (one row; only a clear that removed a row audits),
    # not the interleaving itself, which the single-statement writes rule out by construction.
    test "repeated sets keep one row, and repeated clears all succeed with one audit" do
      tenant = fixture(:tenant)

      sets =
        1..4
        |> Enum.map(fn i ->
          Task.async(fn -> Forge.set_token(tenant.id, "github_pat_race_000#{i}", nil) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.all?(sets, &match?({:ok, %{has_token: true}}, &1))

      assert AdminRepo.aggregate(
               from(c in TenantCredential, where: c.tenant_id == ^tenant.id),
               :count
             ) == 1

      clears =
        1..3
        |> Enum.map(fn _ -> Task.async(fn -> Forge.clear_token(tenant.id, nil) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.all?(clears, &match?({:ok, %{has_token: false}}, &1))
      assert Forge.token(tenant.id) == :none

      cleared =
        AdminRepo.aggregate(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.action == "github_credential.cleared"
          ),
          :count
        )

      assert cleared == 1
    end
  end

  describe "ForgeRepo" do
    test "inspect never shows the token" do
      repo = ForgeRepo.tenant("acme/widgets", "github_pat_inspect001")

      assert inspect(repo) == "#Loopctl.Delivery.ForgeRepo<acme/widgets (tenant)>"
      refute inspect(%{nested: [repo]}) =~ "github_pat_inspect001"
    end
  end
end
