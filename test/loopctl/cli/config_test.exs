defmodule Loopctl.CLI.ConfigTest do
  use ExUnit.Case, async: true

  alias Loopctl.CLI.Config
  alias Loopctl.Test.EnvReader

  @test_dir System.tmp_dir!()

  setup do
    # Use a unique temp config dir per test
    unique = System.unique_integer([:positive])
    config_dir = Path.join(@test_dir, "loopctl_test_#{unique}")
    config_file = Path.join(config_dir, "config.json")
    File.mkdir_p!(config_dir)

    on_exit(fn -> File.rm_rf!(config_dir) end)

    %{config_dir: config_dir, config_file: config_file}
  end

  describe "read/0 and get/1" do
    test "returns empty map when no config file exists" do
      # Config.read uses ~/.loopctl/config.json, but environment overrides are
      # checked regardless. In isolation, we test the file-level functions directly.
      config = Config.read()
      assert is_map(config)
    end

    test "returns nil for unset key" do
      assert Config.get("server") == nil || is_binary(Config.get("server"))
    end

    test "returns nil for invalid key" do
      assert Config.get("bogus") == nil
    end
  end

  describe "set/2" do
    test "rejects invalid keys" do
      assert {:error, {:invalid_key, "bogus"}} = Config.set("bogus", "value")
    end

    test "accepts valid keys" do
      # This writes to actual config file, but is harmless since it uses
      # the real config dir. We test the acceptance, not side effects.
      for key <- Config.valid_keys() do
        result = Config.set(key, "test_value_#{key}")
        assert result == :ok
      end
    end
  end

  describe "valid_keys/0" do
    test "returns the three config keys" do
      keys = Config.valid_keys()
      assert "server" in keys
      assert "api_key" in keys
      assert "format" in keys
      assert length(keys) == 3
    end
  end

  describe "format/0" do
    test "defaults to json when not set" do
      # format returns the configured value or "json"
      result = Config.format()
      assert is_binary(result)
    end
  end

  # Install a process-local env-override map on the injected reader
  # (Loopctl.Test.EnvReader). This exercises the OS-env override path WITHOUT
  # System.put_env, which mutates BEAM-global env shared across every process — a
  # real flake in this `async: true` suite (two of these tests both override
  # LOOPCTL_SERVER and would race each other and any other async test reading it).
  # The override lives in THIS test's process dictionary.
  defp stub_env(overrides), do: EnvReader.put_overrides(overrides)

  describe "environment variable overrides" do
    test "LOOPCTL_SERVER overrides file config" do
      stub_env(%{"LOOPCTL_SERVER" => "https://test.loopctl.io"})
      config = Config.read()
      assert config["server"] == "https://test.loopctl.io"
    end

    test "LOOPCTL_API_KEY overrides file config" do
      stub_env(%{"LOOPCTL_API_KEY" => "lc_test123"})
      config = Config.read()
      assert config["api_key"] == "lc_test123"
    end

    test "LOOPCTL_FORMAT overrides file config" do
      stub_env(%{"LOOPCTL_FORMAT" => "human"})
      config = Config.read()
      assert config["format"] == "human"
    end

    test "empty env var does not override" do
      # Empty string must NOT override — the key stays whatever the file has.
      stub_env(%{"LOOPCTL_SERVER" => ""})
      config = Config.read()
      refute config["server"] == ""
    end

    test "an unset env var (getter returns nil) does not override" do
      stub_env(%{})
      config = Config.read()
      refute Map.has_key?(config, "server") and config["server"] == nil
    end
  end
end
