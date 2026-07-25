defmodule Mix.Tasks.Loopctl.CheckEnvDocsTest do
  @moduledoc """
  Tests for the operator env-var doc guard.

  The point of these tests is the FAILING direction. A doc guard that has only ever
  been observed passing is indistinguishable from one that can never fail — which is
  exactly how the repo accumulated 24 undocumented variables while every gate stayed
  green. So each test asserts a non-empty violation set, not just "no crash".
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopctl.CheckEnvDocs

  describe "scan_env_vars/1" do
    test "finds get_env and fetch_env! reads" do
      source = """
      config :app, url: System.get_env("DATABASE_URL")
      secret = System.fetch_env!("SECRET_KEY_BASE")
      """

      assert CheckEnvDocs.scan_env_vars(source) ==
               MapSet.new(["DATABASE_URL", "SECRET_KEY_BASE"])
    end

    test "skips full-line comments (the commented-out phx.new TLS boilerplate)" do
      source = """
      #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
        # certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
      real = System.get_env("METRICS_PORT")
      """

      assert CheckEnvDocs.scan_env_vars(source) == MapSet.new(["METRICS_PORT"])
    end

    test "tolerates whitespace inside the call and dedupes repeats" do
      source = """
      a = System.get_env( "FTS_REGCONFIG")
      b = System.get_env("FTS_REGCONFIG") || "english"
      """

      assert CheckEnvDocs.scan_env_vars(source) == MapSet.new(["FTS_REGCONFIG"])
    end

    test "ignores non-literal and lowercase reads" do
      source = ~S"""
      x = System.get_env(var_name)
      y = System.get_env("#{prefix}_URL")
      z = System.get_env("lowercase_name")
      """

      assert CheckEnvDocs.scan_env_vars(source) == MapSet.new([])
    end
  end

  describe "undocumented/2 — the failing direction" do
    test "flags a variable that appears nowhere in the docs" do
      vars = MapSet.new(["DOCUMENTED_ONE", "MISSING_ONE"])
      docs = "| `DOCUMENTED_ONE` | `5` | Something. |"

      assert CheckEnvDocs.undocumented(vars, docs) == ["MISSING_ONE"]
    end

    test "a SUBSTRING match does not count as documented" do
      # The failure mode that makes doc guards go quietly vacuous: `POOL_SIZE`
      # must not be satisfied by an unrelated `ADMIN_POOL_SIZE` row.
      docs = "| `ADMIN_POOL_SIZE` | `3` | AdminRepo pool. |"

      assert CheckEnvDocs.undocumented(["POOL_SIZE"], docs) == ["POOL_SIZE"]
      assert CheckEnvDocs.undocumented(["ADMIN_POOL_SIZE"], docs) == []
    end

    test "returns every missing variable, sorted" do
      vars = ["ZED_VAR", "ALPHA_VAR", "MID_VAR"]
      assert CheckEnvDocs.undocumented(vars, "nothing here") == ~w(ALPHA_VAR MID_VAR ZED_VAR)
    end

    test "an empty docs file flags everything (guard cannot pass on a blank doc)" do
      vars = ["A_VAR", "B_VAR"]
      assert CheckEnvDocs.undocumented(vars, "") == ["A_VAR", "B_VAR"]
    end
  end

  describe "the live repo" do
    test "every runtime.exs env var is documented, and the scan is not vacuous" do
      vars = CheckEnvDocs.scan_env_vars(File.read!("config/runtime.exs"))

      # Non-vacuity: assert the scan actually matched a substantial set. Without
      # this, a broken regex would make the assertion below trivially true.
      assert MapSet.size(vars) >= 20,
             "scan found only #{MapSet.size(vars)} vars in runtime.exs — the scan is broken"

      assert CheckEnvDocs.undocumented(vars, File.read!("deploy/FLY_SECRETS.md")) == [],
             "undocumented operator env vars — run: mix loopctl.check_env_docs"
    end
  end
end
