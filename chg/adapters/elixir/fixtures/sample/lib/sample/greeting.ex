defmodule Sample.Greeting do
  @moduledoc "Reads an external resource at compile time."
  @external_resource "priv/greeting.txt"
  @text File.read!("priv/greeting.txt")
  def text, do: String.trim(@text)
end
