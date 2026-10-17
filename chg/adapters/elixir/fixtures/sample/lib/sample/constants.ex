defmodule Sample.Constants do
  @moduledoc "Called only while a test file compiles."
  def answer, do: 42
end

defmodule Sample.Spawned do
  @moduledoc "Called only by a process a test file's compile starts."
  def answer, do: 43
end
