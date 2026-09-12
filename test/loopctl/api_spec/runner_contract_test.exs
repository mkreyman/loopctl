defmodule Loopctl.ApiSpec.RunnerContractTest do
  use ExUnit.Case, async: true

  alias Loopctl.ApiSpec.RunnerContract

  @join %{
    "contract_version" => "1.0.0",
    "machine" => "minis",
    "cores" => 16,
    "memory_mb" => 28_000,
    "repos" => ["mkreyman/home_care_billing"],
    "max_sessions" => 2,
    "in_flight" => 0,
    "draining" => false
  }

  @sample %{
    "sampled_at" => "2026-09-12T20:00:00Z",
    "loadavg_1m" => 0.5,
    "free_ram_mb" => 1_000,
    "free_disk_mb" => 5_000
  }

  describe "the checked-in export" do
    test "matches the declarations — run `mix loopctl.runner_contract` if this fails" do
      path = Path.join(File.cwd!(), RunnerContract.export_path())
      assert File.read!(path) == RunnerContract.encoded_json_schema()
    end

    test "declares every schema the contract names, and requires parent on trace events" do
      defs = RunnerContract.json_schema()["$defs"]

      for mod <- RunnerContract.schema_modules() do
        assert Map.has_key?(defs, mod.schema().title)
      end

      assert "parent" in defs["RunnerTraceEvent"]["required"]
      assert defs["RunnerTraceEvent"]["properties"]["parent"]["type"] == ["string", "null"]
      assert "claim_epoch" in defs["RunnerDispatch"]["required"]
    end
  end

  describe "cast_join/1" do
    test "accepts a valid payload and keeps only declared fields" do
      payload = @join |> Map.put("sample", @sample) |> Map.put("smuggled", "x")

      assert {:ok, join} = RunnerContract.cast_join(payload)
      assert join.machine == "minis"
      assert join.sample.free_disk_mb == 5_000
      refute Map.has_key?(join, :smuggled)
      refute Enum.any?(Map.keys(join), &is_binary/1)
    end

    test "drops undeclared keys inside nested objects too" do
      sample = Map.put(@sample, "padding", String.duplicate("x", 1_000))

      assert {:ok, join} = RunnerContract.cast_join(Map.put(@join, "sample", sample))

      assert Map.keys(join.sample) |> Enum.sort() ==
               [:free_disk_mb, :free_ram_mb, :loadavg_1m, :sampled_at]

      assert {:ok, status} = RunnerContract.cast_status(%{"sample" => sample})
      refute Enum.any?(Map.keys(status.sample), &is_binary/1)
    end

    test "accepts any minor or patch of the spoken major" do
      assert {:ok, _} = RunnerContract.cast_join(%{@join | "contract_version" => "1.9.3"})
    end

    test "refuses another major" do
      assert {:error, {:unsupported_contract_version, "2.0.0", _}} =
               RunnerContract.cast_join(%{@join | "contract_version" => "2.0.0"})

      assert {:error, {:unsupported_contract_version, "11.0.0", _}} =
               RunnerContract.cast_join(%{@join | "contract_version" => "11.0.0"})
    end

    test "refuses every missing required field" do
      for field <- Map.keys(@join) do
        assert {:error, {:invalid, _}} = RunnerContract.cast_join(Map.delete(@join, field)),
               "expected missing #{field} to be refused"
      end
    end

    test "refuses out-of-bound values" do
      for {field, value} <- [
            {"cores", 0},
            {"max_sessions", 65},
            {"in_flight", -1},
            {"machine", "Mac Mini"},
            {"repos", ["not-a-repo"]},
            {"repos", Enum.map(1..51, &"o/r#{&1}")},
            {"contract_version", "1.0"}
          ] do
        assert {:error, {:invalid, _}} = RunnerContract.cast_join(Map.put(@join, field, value)),
               "expected #{field}=#{inspect(value)} to be refused"
      end
    end

    test "refuses a partial health sample" do
      assert {:error, {:invalid, _}} =
               RunnerContract.cast_join(
                 Map.put(@join, "sample", Map.delete(@sample, "free_disk_mb"))
               )
    end

    test "refuses a non-object" do
      assert {:error, {:invalid, _}} = RunnerContract.cast_join("minis")
      assert {:error, {:invalid, _}} = RunnerContract.cast_join(nil)
    end
  end

  describe "cast_status/1" do
    test "accepts any subset of the status fields" do
      assert {:ok, %{in_flight: 1}} = RunnerContract.cast_status(%{"in_flight" => 1})
      assert {:ok, %{draining: true}} = RunnerContract.cast_status(%{"draining" => true})
      assert {:ok, %{sample: _}} = RunnerContract.cast_status(%{"sample" => @sample})
    end

    test "refuses a status carrying no declared field" do
      assert {:error, {:invalid, _}} = RunnerContract.cast_status(%{})
      assert {:error, {:invalid, _}} = RunnerContract.cast_status(%{"machine" => "mac-mini"})
    end
  end
end
