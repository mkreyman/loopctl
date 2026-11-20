defmodule Sample.Billing do
  @moduledoc "Depends on Sample.Accounts at runtime."
  def invoice(id), do: "invoice for " <> Sample.Accounts.name(id)
end
