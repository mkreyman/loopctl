defmodule Sample.GreetingTest do
  use Sample.Case, async: true
  # Evaluated while this file compiles, alongside the other files' tests: one call made
  # by the compiling process, one by a process it starts.
  @at_compile {Sample.Constants.answer(), Task.await(Task.async(&Sample.Spawned.answer/0))}
  test "text", do: assert(Sample.Greeting.text() == "hello" and @at_compile == {42, 43})
end
