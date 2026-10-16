defmodule Sample.AccountsTest do
  use Sample.Case, async: true
  test "name", do: assert(Sample.Accounts.name(1) == "user-1")
end
