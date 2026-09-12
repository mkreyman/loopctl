defmodule Loopctl.DeliveryGates.GlobTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.Glob

  defp matches?(pattern, path) do
    {:ok, glob} = Glob.compile(pattern)
    Glob.match?(glob, path)
  end

  describe "compile/1" do
    test "rejects a pattern that is not a non-empty UTF-8 binary" do
      assert Glob.compile("") == {:error, :invalid_pattern}
      assert Glob.compile(nil) == {:error, :invalid_pattern}
      assert Glob.compile(:atom) == {:error, :invalid_pattern}
      assert Glob.compile(<<0xFF, 0xFE>>) == {:error, :invalid_pattern}
    end

    test "keeps the source pattern for reporting" do
      assert {:ok, %Glob{source: "priv/rates/**"}} = Glob.compile("priv/rates/**")
    end
  end

  describe "**" do
    test "matches across directory separators" do
      assert matches?("priv/rates/**", "priv/rates/2026.csv")
      assert matches?("priv/rates/**", "priv/rates/nested/deep/2026.csv")
    end

    test "requires the literal prefix" do
      refute matches?("priv/rates/**", "priv/rates")
      refute matches?("priv/rates/**", "priv/ratesheet.csv")
      refute matches?("priv/rates/**", "other/priv/rates/2026.csv")
    end

    test "embedded in a segment" do
      assert matches?("lib/**.ex", "lib/app/payments/submit.ex")
      refute matches?("lib/**.ex", "lib/app/payments/submit.exs")
    end

    test "/**/ matches zero or more intermediate directories" do
      assert matches?("lib/**/data_migrations/**", "lib/app/data_migrations/x.ex")
      assert matches?("lib/**/data_migrations/**", "lib/a/b/c/data_migrations/x.ex")
      assert matches?("lib/**/data_migrations/**", "lib/data_migrations/x.ex")
      refute matches?("lib/**/data_migrations/**", "lib/app/data_migrationsx/x.ex")
      refute matches?("lib/**/data_migrations/**", "libdata_migrations/x.ex")
    end

    test "a leading **/ matches at the root too" do
      assert matches?("**/runtime.exs", "runtime.exs")
      assert matches?("**/runtime.exs", "config/runtime.exs")
      refute matches?("**/runtime.exs", "config/xruntime.exs")
    end

    test "crosses a newline in a path" do
      assert matches?("priv/**", "priv/odd\nname.csv")
    end
  end

  describe "*" do
    test "matches within one segment only" do
      assert matches?("lib/app_web/plugs/*auth*", "lib/app_web/plugs/require_auth.ex")
      assert matches?("lib/*.ex", "lib/app.ex")
      refute matches?("lib/*.ex", "lib/app/payments.ex")
    end

    test "matches the empty string" do
      assert matches?("lib/app*.ex", "lib/app.ex")
    end
  end

  describe "?" do
    test "matches exactly one non-slash character" do
      assert matches?("priv/rates/202?.csv", "priv/rates/2026.csv")
      refute matches?("priv/rates/202?.csv", "priv/rates/202.csv")
      refute matches?("priv/rates/202?.csv", "priv/rates/20266.csv")
      refute matches?("a?b", "a/b")
    end

    test "matches one codepoint, not one byte" do
      assert matches?("docs/?.md", "docs/é.md")
    end
  end

  describe "literals" do
    test "regex metacharacters carry no meaning" do
      assert matches?("lib/app.ex", "lib/app.ex")
      refute matches?("lib/app.ex", "lib/appXex")
      assert matches?("a[b].{c}+(d)|$^", "a[b].{c}+(d)|$^")
      refute matches?("a[b]", "ab")
    end

    test "is anchored at both ends" do
      refute matches?("config/runtime.exs", "config/runtime.exs.bak")
      refute matches?("config/runtime.exs", "x/config/runtime.exs")
    end

    test "is case-sensitive" do
      refute matches?("lib/app_web/router.ex", "lib/App_web/router.ex")
    end
  end

  test "a non-binary path never matches" do
    {:ok, glob} = Glob.compile("**")
    refute Glob.match?(glob, nil)
    refute Glob.match?(glob, :path)
    refute Glob.match?(glob, <<0xFF>>)
  end
end
