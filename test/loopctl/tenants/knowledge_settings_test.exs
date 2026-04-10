defmodule Loopctl.Tenants.KnowledgeSettingsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Tenants

  # --- TC-21.6.6: Update auto_extract setting via tenant settings endpoint ---

  describe "update_tenant/2 with knowledge_auto_extract" do
    test "allows setting knowledge_auto_extract to false" do
      tenant = fixture(:tenant)

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{
                 "settings" => %{"knowledge_auto_extract" => false}
               })

      assert updated.settings["knowledge_auto_extract"] == false
    end

    test "allows setting knowledge_auto_extract to true" do
      tenant = fixture(:tenant, %{settings: %{"knowledge_auto_extract" => false}})

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{
                 "settings" => %{"knowledge_auto_extract" => true}
               })

      assert updated.settings["knowledge_auto_extract"] == true
    end

    test "rejects non-boolean value for knowledge_auto_extract" do
      tenant = fixture(:tenant)

      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{
                 "settings" => %{"knowledge_auto_extract" => "yes"}
               })

      assert errors_on(changeset).settings != []
    end

    test "rejects integer value for knowledge_auto_extract" do
      tenant = fixture(:tenant)

      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{
                 "settings" => %{"knowledge_auto_extract" => 1}
               })

      assert errors_on(changeset).settings != []
    end

    test "merges settings (preserves existing keys)" do
      tenant = fixture(:tenant, %{settings: %{"existing_key" => "value"}})

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{
                 "settings" => %{"knowledge_auto_extract" => false}
               })

      assert updated.settings["knowledge_auto_extract"] == false
      assert updated.settings["existing_key"] == "value"
    end

    # --- TC-21.6.7: Default auto_extract is true for new tenants ---

    test "new tenants default to empty settings (auto_extract defaults to true)" do
      tenant = fixture(:tenant)

      # Empty settings map -- the default for knowledge_auto_extract is true
      assert tenant.settings == %{}
    end
  end
end
