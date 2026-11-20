defmodule Sample.BillingTest do
  use Sample.Case, async: true
  test "invoice", do: assert(Sample.Billing.invoice(1) == "invoice for user-1")
end
