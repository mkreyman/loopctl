defmodule Loopctl.ReleaseSetCheckTest do
  @moduledoc """
  US-52.8: `Loopctl.ReleaseSet.check/3` and the runner join it gates, judged against an
  injected components map so no case depends on the committed manifest's numbers.

  No tenant isolation case: the check reads no tenant data, only the compiled release set.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ReleaseSet

  @components %{
    "runner" => %{minimum: "unreported", version: "0.2.0"},
    "chg" => %{minimum: "0.2.0", version: "0.3.0"},
    "mcp" => %{minimum: "3.0.0", version: "3.19.1"}
  }

  describe "check/3 (TC-52.8.1)" do
    test "an unreported minimum admits nil and any version" do
      for sent <- [nil, "0.1.0", "0.9.0"],
          do: assert(:ok == ReleaseSet.check(:runner, sent, @components))
    end

    test "a version minimum admits at or above it and refuses below, garbage and nil" do
      assert {:error, {:incompatible_client_version, refusal}} =
               ReleaseSet.check(:chg, "0.1.9", @components)

      assert refusal == %{component: "chg", sent: "0.1.9", minimum: "0.2.0", version: "0.3.0"}

      assert :ok = ReleaseSet.check(:chg, "0.2.0", @components)
      assert :ok = ReleaseSet.check("chg", "0.4.0", @components)

      for sent <- ["x", nil, "unreported", "0.2"] do
        assert {:error, {:incompatible_client_version, %{minimum: "0.2.0", sent: ^sent}}} =
                 ReleaseSet.check(:chg, sent, @components)
      end
    end

    test "a pre-release below the minimum's release is below it" do
      assert {:error, _} = ReleaseSet.check(:mcp, "3.0.0-rc.1", @components)
      assert :ok = ReleaseSet.check(:mcp, "3.0.1-rc.1", @components)
    end

    test "the compiled set is the default and every client is in it" do
      for client <- ReleaseSet.clients() do
        %{version: version} = ReleaseSet.component(client)
        assert :ok == ReleaseSet.check(client, version)
      end
    end
  end

  describe "cast_join/2 (TC-52.8.2)" do
    @gated Map.put(@components, "runner", %{minimum: "0.2.0", version: "0.3.0"})

    defp join(attrs) do
      Map.merge(
        %{
          "contract_version" => RunnerContract.version(),
          "machine" => "minis",
          "cores" => 16,
          "memory_mb" => 28_000,
          "repos" => ["mkreyman/loopctl"],
          "max_sessions" => 2,
          "in_flight" => 0,
          "draining" => false
        },
        attrs
      )
    end

    test "refuses a runner below the minimum, and one sending none" do
      assert {:error, {:incompatible_client_version, %{sent: "0.1.0", minimum: "0.2.0"}}} =
               RunnerContract.cast_join(join(%{"runner_version" => "0.1.0"}), @gated)

      assert {:error, {:incompatible_client_version, %{sent: nil}}} =
               RunnerContract.cast_join(join(%{}), @gated)
    end

    test "admits a runner at the minimum and drops a property the contract does not declare (AC-52.8.8)" do
      assert {:ok, meta} =
               RunnerContract.cast_join(
                 join(%{"runner_version" => "0.2.0", "future_field" => "x"}),
                 @gated
               )

      assert meta.runner_version == "0.2.0"
      refute Map.has_key?(meta, :future_field)
      refute Map.has_key?(meta, "future_field")
    end

    test "the refusal is a published, permanent join reason with its fields" do
      assert "incompatible_client_version" in RunnerContract.error_reasons()["join"]
      assert "incompatible_client_version" in RunnerContract.permanent_errors()["*"]

      assert RunnerContract.error_fields()["join"]["incompatible_client_version"] ==
               ~w(component sent minimum)
    end
  end
end
