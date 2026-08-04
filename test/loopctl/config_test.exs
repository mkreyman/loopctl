defmodule Loopctl.ConfigTest do
  use ExUnit.Case, async: true

  alias Loopctl.Config
  alias Mix.Tasks.Loopctl.CheckEnvDocs

  describe "opt_out_enabled?/1" do
    test "is true when the var is unset (nil)" do
      assert Config.opt_out_enabled?(nil)
    end

    test "false/0 disable, trimmed and case-insensitively" do
      for value <- ["false", "0", "FALSE", "False", " false ", "\t0\n"] do
        refute Config.opt_out_enabled?(value), "expected #{inspect(value)} to disable"
      end
    end

    # The point of the opt-OUT parse (#376): a typo, an empty value or an unrecognized
    # spelling must leave the flag ON, where its guard is still watching. Normalizing
    # this to the `in ~w(true 1)` opt-IN shape used elsewhere in runtime.exs would make
    # every one of these silently disable the flag instead.
    test "anything else stays enabled, including typos and unrecognized spellings" do
      for value <- ["true", "1", "flase", "off", "no", ""] do
        assert Config.opt_out_enabled?(value), "expected #{inspect(value)} to stay enabled"
      end
    end

    # The read stays a LITERAL name (not one built by interpolation) so the textual
    # scan behind mix loopctl.check_env_docs keeps seeing the var. Since #566 that
    # guard scans lib/ as well, so this no longer pins the read to runtime.exs — but
    # the read IS there, and a scan that stopped finding it would mean the literal
    # shape had been refactored away, which is the half still worth pinning.
    test "SCALE_ALERTS_ENABLED is read literally in runtime.exs, under the env-docs guard" do
      assert "config/runtime.exs"
             |> File.read!()
             |> CheckEnvDocs.scan_env_vars()
             |> Enum.member?("SCALE_ALERTS_ENABLED")
    end
  end
end
