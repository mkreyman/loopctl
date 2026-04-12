defmodule Loopctl.AuditChain.ViolationsTest do
  @moduledoc """
  Tests for US-26.1.4 — violation discovery and management.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.PendingViolation
  alias Loopctl.AuditChain.Violations

  setup :verify_on_exit!

  defp create_violation(attrs \\ %{}) do
    tenant = fixture(:tenant)

    base = %{
      violation_type: "nil_agent_non_user_key",
      entity_type: "api_key",
      entity_id: Ecto.UUID.generate(),
      tenant_id: tenant.id,
      detail: %{"role" => "agent"}
    }

    %PendingViolation{}
    |> PendingViolation.changeset(Map.merge(base, attrs))
    |> AdminRepo.insert!()
  end

  describe "list_violations/1" do
    test "returns pending violations by default" do
      v1 = create_violation()
      _v2 = create_violation(%{status: "resolved"})

      result = Violations.list_violations()
      ids = Enum.map(result.data, & &1.id)

      assert v1.id in ids
      assert result.meta.total_count >= 1
    end

    test "filters by violation_type" do
      create_violation(%{violation_type: "cross_role_binding"})
      create_violation(%{violation_type: "nil_agent_non_user_key"})

      result = Violations.list_violations(violation_type: "cross_role_binding")
      assert Enum.all?(result.data, &(&1.violation_type == "cross_role_binding"))
    end
  end

  describe "pending_count/0" do
    test "counts only pending violations" do
      before = Violations.pending_count()
      create_violation()
      create_violation(%{status: "resolved"})

      assert Violations.pending_count() == before + 1
    end
  end

  describe "resolve/3" do
    test "resolves a violation with note" do
      v = create_violation()

      assert {:ok, resolved} = Violations.resolve(v.id, "Fixed manually")
      assert resolved.status == "resolved"
      assert resolved.resolution_note == "Fixed manually"
      assert resolved.resolved_at != nil
    end

    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Violations.resolve(Ecto.UUID.generate(), "test")
    end
  end

  describe "ignore/2" do
    test "ignores a violation" do
      v = create_violation()

      assert {:ok, ignored} = Violations.ignore(v.id, "Not relevant")
      assert ignored.status == "ignored"
    end
  end
end
