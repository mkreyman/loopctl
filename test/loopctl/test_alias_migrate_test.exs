defmodule Loopctl.TestAliasMigrateTest do
  # The `test` aliases migrate in a separate VM (`Loopctl.MixProject.migrate_out_of_vm/1`).
  # Migrating in this one leaves every pending migration's module loaded, and a migration
  # test that `Code.require_file`s the same file then fails `--warnings-as-errors` with
  # "redefining module", but only on a fresh database, which CI's test job (it migrates in
  # its own step) never has.
  use ExUnit.Case, async: true

  @in_vm_migrate ~r/\b(ecto\.(migrate|setup|reset)|do)\b/

  for {alias_name, run} <- [test: "test", "test.e2e": "test --only e2e"] do
    test "the #{alias_name} alias creates, migrates out of the VM, then tests" do
      steps = Keyword.fetch!(Mix.Project.config()[:aliases], unquote(alias_name))

      assert steps == [
               "ecto.create --quiet",
               &Loopctl.MixProject.migrate_out_of_vm/1,
               unquote(run)
             ]

      refute Enum.any?(steps, &(is_binary(&1) and &1 =~ @in_vm_migrate))
    end
  end
end
