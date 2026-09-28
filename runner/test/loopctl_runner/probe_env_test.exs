defmodule LoopctlRunner.ProbeEnvTest do
  @moduledoc """
  The liveness probe is the SECOND Port that launches the CLI, and it had its own security list.

  `ProcessGroup.run/5` spawns `claude agents --json` while a session is running. It used to unset
  one name, hand-copied, with nothing tying it to any other list, and the two drifted. It now runs
  the runner's own scrub — the session's billing key from `Session.credential_env/0`, the runner's
  credential names and the shape deny — and this test is what makes that falsifiable rather than
  a comment claiming it.
  """

  # Mutates the OS environment, which spawned processes inherit.
  use ExUnit.Case, async: false

  alias LoopctlRunner.ProcessGroup

  test "the probe's Port gets the runner's credential scrub, by name and by shape" do
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

  test "extra_env adds to the scrub and sets names, and can never take a name out of it" do
    # The runner's own submodule git passes GIT_TERMINAL_PROMPT and unsets the repo-locating names
    # here. A caller able to hand a scrubbed credential back to the Port would make the scrub a
    # default rather than a rule. Values printed are this test's own, never the environment's.
    saved = System.get_env("GH_TOKEN")
    System.put_env("GH_TOKEN", "not-a-real-value")

    try do
      script = ~s(printf '%s|%s' "${LOOP_PROBE_SET-unset}" "${GH_TOKEN+present}")

      assert {:ok, "1|", 0} =
               ProcessGroup.run("/bin/sh", ["-c", script], 10_000, [
                 {"LOOP_PROBE_SET", "1"},
                 {"GH_TOKEN", "handed-back"}
               ])
    after
      if saved, do: System.put_env("GH_TOKEN", saved), else: System.delete_env("GH_TOKEN")
    end
  end
end
