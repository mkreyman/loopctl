defmodule Loopctl.Auth.RoleTest do
  use ExUnit.Case, async: true

  alias Loopctl.Auth.Role

  describe "role_at_least?/2" do
    test "superadmin >= user" do
      assert Role.role_at_least?(:superadmin, :user)
    end

    test "superadmin >= agent" do
      assert Role.role_at_least?(:superadmin, :agent)
    end

    test "user >= orchestrator" do
      assert Role.role_at_least?(:user, :orchestrator)
    end

    test "orchestrator >= agent" do
      assert Role.role_at_least?(:orchestrator, :agent)
    end

    test "orchestrator >= orchestrator" do
      assert Role.role_at_least?(:orchestrator, :orchestrator)
    end

    test "agent < orchestrator" do
      refute Role.role_at_least?(:agent, :orchestrator)
    end

    test "agent < user" do
      refute Role.role_at_least?(:agent, :user)
    end

    test "orchestrator < user" do
      refute Role.role_at_least?(:orchestrator, :user)
    end
  end

  describe "level/1" do
    test "returns correct levels" do
      assert Role.level(:superadmin) == 4
      assert Role.level(:user) == 3
      assert Role.level(:orchestrator) == 2
      assert Role.level(:agent) == 1
    end
  end
end
