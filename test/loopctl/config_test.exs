defmodule Loopctl.ConfigTest do
  use ExUnit.Case, async: true

  alias Loopctl.Config

  # A unique var name per test keeps the (process-global) `System.put_env/2` safe under
  # `async: true`: no two tests ever read or write the same name.
  setup do
    var = "LOOPCTL_TEST_OPT_OUT_#{System.unique_integer([:positive])}"
    on_exit(fn -> System.delete_env(var) end)
    {:ok, var: var}
  end

  describe "opt_out_flag/1" do
    test "is true when the var is unset", %{var: var} do
      assert Config.opt_out_flag(var)
    end

    test "false/0 disable, trimmed and case-insensitively", %{var: var} do
      for value <- ["false", "0", "FALSE", "False", " false ", "\t0\n"] do
        System.put_env(var, value)
        refute Config.opt_out_flag(var), "expected #{inspect(value)} to disable"
      end
    end

    # The point of the opt-OUT parse (#376): a typo, an empty value or an unrecognized
    # spelling must leave the flag ON, where its guard is still watching. Normalizing
    # this to the `in ~w(true 1)` opt-IN shape used elsewhere in runtime.exs would make
    # every one of these silently disable the flag instead.
    test "anything else stays enabled, including typos and unrecognized spellings", %{var: var} do
      for value <- ["true", "1", "flase", "off", "no", ""] do
        System.put_env(var, value)
        assert Config.opt_out_flag(var), "expected #{inspect(value)} to stay enabled"
      end
    end
  end
end
