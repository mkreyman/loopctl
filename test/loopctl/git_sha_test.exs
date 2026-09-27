defmodule Loopctl.GitShaTest do
  @moduledoc "The one rule for a git object id (US-45.7 review round 3)."

  use ExUnit.Case, async: true

  alias Loopctl.GitSha

  test "40 or 64 lowercase hex characters, and nothing else" do
    assert GitSha.valid?(String.duplicate("a", 40))
    assert GitSha.valid?(String.duplicate("0", 64))

    refute GitSha.valid?(String.duplicate("a", 39))
    refute GitSha.valid?(String.duplicate("a", 41))
    refute GitSha.valid?(String.duplicate("a", 63))
    refute GitSha.valid?(String.duplicate("A", 40))
    refute GitSha.valid?(String.duplicate("g", 40))
    refute GitSha.valid?(String.duplicate("a", 40) <> "\n")
    refute GitSha.valid?(nil)
    refute GitSha.valid?(123)
  end
end
