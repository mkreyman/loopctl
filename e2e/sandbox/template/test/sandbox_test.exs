defmodule SandboxTest do
  use ExUnit.Case, async: true

  test "the sandbox compiles" do
    assert Code.ensure_loaded?(Sandbox)
  end
end
