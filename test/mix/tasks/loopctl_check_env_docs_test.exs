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

    test "#566: a passing MENTION in prose does not count as documented" do
      # How the guard went quietly vacuous for `STH_SWEEP_CRON`: it was named once, in an
      # aside explaining a DIFFERENT decision ("after the STH_SWEEP_CRON incident"), and a
      # whole-word text match read that as documentation. An operator learns neither the
      # default nor what the knob does from a sentence about something else, so the match
      # is anchored to a table row — where a default and a description sit structurally
      # adjacent and cannot be omitted by accident.
      docs = """
      > A deliberate choice after the `STH_SWEEP_CRON` incident, so a bad placeholder
      > can never take the app down at startup.
      """

      assert CheckEnvDocs.undocumented(["STH_SWEEP_CRON"], docs) == ["STH_SWEEP_CRON"]

      assert CheckEnvDocs.undocumented(
               ["STH_SWEEP_CRON"],
               docs <> "\n| `STH_SWEEP_CRON` | `*/5 * * * *` | STH safety sweep cron |"
             ) == []
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
    setup do
      %{
        vars:
          Enum.reduce(CheckEnvDocs.sources(), MapSet.new(), fn {pattern, min}, acc ->
            found = CheckEnvDocs.scan_paths(pattern)

            # Per-source non-vacuity, asserted per source for the same reason the task
            # enforces it per source: over the UNION, runtime.exs's ~42 vars would clear
            # any sane floor on their own, so a `lib/**/*.ex` glob that silently matched
            # nothing would still look healthy.
            assert MapSet.size(found) >= min,
                   "scan of #{pattern} found only #{MapSet.size(found)} vars — it is broken"

            MapSet.union(acc, found)
          end)
      }
    end

    test "every scanned env var is documented", %{vars: vars} do
      assert CheckEnvDocs.undocumented(vars, File.read!("deploy/FLY_SECRETS.md")) == [],
             "undocumented operator env vars — run: mix loopctl.check_env_docs"
    end

    test "#566: the scan covers lib/ as well as config/runtime.exs", %{vars: vars} do
      # Iterating `sources/0` above means the assertion above cannot notice a source being
      # DROPPED from that list — it would simply iterate one fewer and pass. These anchors
      # are named because each can only come from one source, which is what makes removing
      # either source a test failure rather than a quieter guard.
      #
      # `OBAN_*` is the family that motivated #566: runtime.exs does evaluate it at boot,
      # but via `Loopctl.ObanConfig`, so the literal name never appears in the config file
      # and eight variables sat outside a green guard.
      assert "OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS" in vars,
             "lib/ is no longer scanned — the #566 blind spot is back"

      assert "DATABASE_URL" in vars, "config/runtime.exs is no longer scanned"
    end
  end

  describe "scan_paths/1" do
    test "raises rather than reporting zero when a wildcard matches nothing" do
      # A wildcard that matches no file yields an empty set, which is indistinguishable
      # from a source that genuinely reads no env vars — and a mistyped path is by far the
      # likelier cause. Fail loud instead.
      assert_raise Mix.Error, ~r/matched no files/, fn ->
        CheckEnvDocs.scan_paths("lib/no/such/directory/**/*.ex")
      end
    end
  end
end
