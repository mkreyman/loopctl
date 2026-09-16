defmodule LoopctlRunner.ProbeEnvTest do
  @moduledoc """
  The liveness probe is the SECOND Port that launches the CLI, and it had its own security list.

  `ProcessGroup.run/3` spawns `claude agents --json` while a session is running. It used to unset
  one name, hand-copied, with nothing tying it to the list a session gets — so that list grew to
  eight names and a shape deny while this one still said `ANTHROPIC_API_KEY`. This test is what
  makes the binding falsifiable rather than a comment claiming it.
  """

  # Mutates the OS environment, which spawned processes inherit.
  use ExUnit.Case, async: false

  alias LoopctlRunner.ProcessGroup

  test "the probe's Port gets the same credential scrub a session does" do
    nonce = Integer.to_string(System.unique_integer([:positive]))

    vars = [
      {"ANTHROPIC_API_KEY", "not-a-real-value-" <> nonce},
      {"GH_TOKEN", "not-a-real-value-" <> nonce},
      {"SSH_AUTH_SOCK", "/tmp/not-a-real-agent-socket-" <> nonce},
      # On no list at all: only the shape deny can remove this one.
      {"NPM_TOKEN", "not-a-real-value-" <> nonce}
    ]

    saved = Enum.map(vars, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    names =
      try do
        {:ok, out, 0} = ProcessGroup.run(System.find_executable("env"), [], 10_000)
        # NAMES ONLY, and the values are dropped here rather than at the assertion: `out` holds
        # this machine's whole environment, and a failing assertion prints what it compared.
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))
      after
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end

    # The probe ran and saw an environment at all, so the refutations below are about a
    # subtraction rather than about an empty list.
    assert "PATH" in names

    for {name, _} <- vars do
      refute name in names, "#{name} reached the liveness probe"
    end
  end
end
