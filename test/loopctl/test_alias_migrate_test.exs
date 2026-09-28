defmodule Loopctl.TestAliasMigrateTest do
  # The `test` aliases migrate in a separate VM. Migrating in this one leaves every pending
  # migration's module loaded, and a migration test that `Code.require_file`s the same file
  # then fails `--warnings-as-errors` with "redefining module", but only on a fresh
  # database, which CI's test job (it migrates in its own step) never has.
  use ExUnit.Case, async: true

  for alias_name <- [:test, :"test.e2e"] do
    test "the #{alias_name} alias migrates out of the test VM" do
      steps = Keyword.fetch!(Mix.Project.config()[:aliases], unquote(alias_name))

      refute Enum.any?(steps, &(is_binary(&1) and &1 =~ ~r/^ecto\.migrate\b/)),
             "#{unquote(alias_name)} runs ecto.migrate in the test VM: #{inspect(steps)}"

      assert "cmd env MIX_ENV=test mix ecto.migrate --quiet" in steps
    end
  end
end
