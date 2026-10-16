defmodule Sample.GreetingTest do
  use Sample.Case, async: true
  test "text", do: assert(Sample.Greeting.text() == "hello")
end
