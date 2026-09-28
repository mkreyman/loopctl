defmodule Loopctl.TestAliasMigrateTest do
  # The `test` aliases migrate in a separate VM (`Loopctl.MixProject.migrate_out_of_vm/1`).
  # Migrating in this one leaves every pending migration's module loaded, and a migration
  # test that `Code.require_file`s the same file then fails `--warnings-as-errors` with
  # "redefining module", but only on a fresh database, which CI's test job (it migrates in
  # its own step) never has.
  use ExUnit.Case, async: true

  for {alias_name, run} <- [test: "test", "test.e2e": "test --only e2e"] do
    test "the #{alias_name} alias creates, migrates out of the VM, then tests" do
      assert Keyword.fetch!(Mix.Project.config()[:aliases], unquote(alias_name)) == [
               "ecto.create --quiet",
               &Loopctl.MixProject.migrate_out_of_vm/1,
               unquote(run)
             ]
    end
  end

  test "no migration module was loaded into the test VM before the suite" do
    preloaded = :persistent_term.get({__MODULE__, :preloaded_migrations})

    assert preloaded == [],
           "migrations ran inside the test VM (e.g. `mix do ecto.migrate + test`), so the " <>
             "migration tests will redefine #{length(preloaded)} modules, such as " <>
             "#{inspect(Enum.take(preloaded, 3))}; run `mix test`, whose " <>
             "alias migrates in a VM of its own"
  end
end
