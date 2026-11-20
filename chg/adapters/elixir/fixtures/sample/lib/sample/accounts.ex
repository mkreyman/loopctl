defmodule Sample.Accounts do
  @moduledoc "A context the billing context calls."
  def name(id), do: "user-#{id}"
end
