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

    test "skips comments — whole-line (phx.new TLS boilerplate) and TRAILING alike" do
      source = """
      #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
        # certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
      cap = default() # override with System.get_env("EXAMPLE_KNOB")
      real = System.get_env("METRICS_PORT")
      """

      assert CheckEnvDocs.scan_env_vars(source) == MapSet.new(["METRICS_PORT"])

      # A `#` inside a STRING is not a comment: cutting the line there hides the read after
      # it — the silent pass this task exists to prevent, from the stripper itself.
      assert CheckEnvDocs.scan_env_vars(~S|u = "https://x/#/a"; System.get_env("A_VAR")|) ==
               MapSet.new(["A_VAR"])
    end

    test "tolerates whitespace inside the call and dedupes repeats" do
      source = """
      a = System.get_env( "FTS_REGCONFIG")
      b = System.get_env("FTS_REGCONFIG") || "english"
      """

      assert CheckEnvDocs.scan_env_vars(source) == MapSet.new(["FTS_REGCONFIG"])
    end

    test "finds a read the formatter wrapped onto the next line" do
      # A per-LINE match sees nothing here: the variable is read at runtime, absent from
      # the docs, and reported as fine — #566's vacuous pass, one level down.
      source = "base =\n  System.get_env(\n    \"METRICS_PORT\"\n  )\n"

      assert CheckEnvDocs.scan_env_vars(source) == MapSet.new(["METRICS_PORT"])
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

    test "a row with a blank default or description does not count as documented" do
      # The cheapest way past a failing guard is a bare row, which teaches an operator
      # neither the default nor what breaks — so the anchor requires both cells.
      assert CheckEnvDocs.undocumented(["NEW_VAR"], "| `NEW_VAR` |  |  |") == ["NEW_VAR"]
      assert CheckEnvDocs.undocumented(["NEW_VAR"], "| `NEW_VAR` | `7` |  |") == ["NEW_VAR"]
      assert CheckEnvDocs.undocumented(["NEW_VAR"], "| `NEW_VAR` | `7` | Does a thing |") == []

      # Same hole in a second shape: a cell pattern matching newlines runs past the end of
      # the row and takes "has a description" from whatever row FOLLOWS.
      borrowed = "| `NEW_VAR` | 7\n| `OTHER_VAR` | 1 | Does a thing |"
      assert CheckEnvDocs.undocumented(["NEW_VAR"], borrowed) == ["NEW_VAR"]
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
      # Seeded with the declared dynamic-read names: no scan can find them, so without this
      # the whitelist's claim that they are documented is #566's unenforced promise again.
      vars =
        Enum.reduce(CheckEnvDocs.sources(), CheckEnvDocs.dynamic_families(), fn {pattern, min},
                                                                                acc ->
          found = CheckEnvDocs.scan_paths(pattern)

          # Per-source non-vacuity, asserted per source for the same reason the task
          # enforces it per source: over the UNION, runtime.exs's ~42 vars would clear
          # any sane floor on their own, so a `lib/**/*.ex` glob that silently matched
          # nothing would still look healthy.
          assert MapSet.size(found) >= min,
                 "scan of #{pattern} found only #{MapSet.size(found)} vars — it is broken"

          MapSet.union(acc, found)
        end)

      %{vars: vars}
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
      # and the family sat outside a green guard.
      assert "OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS" in vars,
             "lib/ is no longer scanned — the #566 blind spot is back"

      assert "DATABASE_URL" in vars, "config/runtime.exs is no longer scanned"
    end
  end

  describe "dynamic_read?/1 and check_dynamic_reads/2" do
    test "flags a runtime-built name, which the literal scan cannot resolve" do
      # The residual #566 shape: an OBAN_QUEUE_ name built at runtime is an operator knob
      # no textual scan can name, so it must FAIL the guard, not pass over in silence.
      assert CheckEnvDocs.dynamic_read?(~S|System.get_env("OBAN_QUEUE_" <> name)|)
      assert CheckEnvDocs.dynamic_read?(~S|System.get_env(env_var)|)
      assert CheckEnvDocs.dynamic_read?(~S|System.get_env("#{prefix}_URL")|)
      assert CheckEnvDocs.dynamic_read?(~S|def read(get \\ &System.get_env/1), do: get.(v)|)
      refute CheckEnvDocs.dynamic_read?(~S|System.get_env("FTS_REGCONFIG")|)
      refute CheckEnvDocs.dynamic_read?("x =\n  System.get_env(\n    \"A_VAR\"\n  )\n")
      refute CheckEnvDocs.dynamic_read?(~S|u = "https://x/#/a"; System.get_env("A_VAR")|)
      refute CheckEnvDocs.dynamic_read?(~S|# was System.get_env(name)|)

      # Each of these failed the build naming a cause that is not true: a lowercase literal
      # (which `scan_env_vars/1` ignores — the two must agree about one input), the
      # zero-arity whole-environment read, and PROSE describing a call rather than making
      # one, which turned a docs-only change red.
      refute CheckEnvDocs.dynamic_read?(~S|System.get_env("https_proxy")|)
      refute CheckEnvDocs.dynamic_read?(~S|all = System.get_env()|)
      refute CheckEnvDocs.dynamic_read?(~s|@doc """\nReads System.get_env(env_var).\n"""|)
    end

    test "check_dynamic_reads/2 raises for an undeclared file, passes for a declared one" do
      # The enforcement half: every file that reads dynamically today is already declared,
      # so driving it through the real tree alone never observes it failing.
      assert_raise Mix.Error, ~r/built at runtime/, fn ->
        CheckEnvDocs.check_dynamic_reads("lib/loopctl/new_thing.ex", "System.get_env(name)")
      end

      assert CheckEnvDocs.check_dynamic_reads(
               "lib/loopctl/oban_config.ex",
               ~S|System.get_env("OBAN_QUEUE_" <> queue)|
             ) == :ok
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
