defmodule Loopctl.E2eAliasTest do
  @moduledoc "TC-52.9.3 (US-52.9): `mix e2e` at the root runs the e2e project's suite."
  use ExUnit.Case, async: true

  test "the root e2e alias runs mix test inside e2e/" do
    aliases = Mix.Project.config()[:aliases]

    assert aliases[:e2e] == ["cmd --cd e2e mix test"]
    assert File.exists?(Path.expand("e2e/mix.exs"))
  end

  test "the e2e workflow's live job runs the alias" do
    workflow = File.read!(Path.expand(".github/workflows/e2e.yml"))
    assert workflow =~ "mix e2e"
  end
end
