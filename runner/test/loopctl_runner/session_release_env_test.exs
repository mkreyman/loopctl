defmodule LoopctlRunner.SessionReleaseEnvTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Session

  # Values are placeholders: tests never record real environment values.
  test "the release's own names are unset, and nothing else" do
    env = %{
      "RELEASE_ROOT" => "/r",
      "RELEASE_COOKIE" => "c",
      "RELEASE_NODE" => "n",
      "EMU" => "beam",
      "PROGNAME" => "erl",
      "ROOTDIR" => "/r/erts",
      "BINDIR" => "/r/erts/bin",
      "ERL_CRASH_DUMP_SECONDS" => "0",
      "LOOPCTL_RUNNER_DAEMON" => "1",
      "LOOPCTL_RUNNER_CONFIG" => "/c",
      "ERL_AFLAGS" => "-kernel shell_history enabled",
      "HOME" => "/home/u",
      "MIX_ENV" => "test",
      "RELEASED" => "not a release name"
    }

    assert Session.release_env(env) ==
             ~w(BINDIR EMU ERL_CRASH_DUMP_SECONDS LOOPCTL_RUNNER_CONFIG LOOPCTL_RUNNER_DAEMON
                PROGNAME RELEASE_COOKIE RELEASE_NODE RELEASE_ROOT ROOTDIR)
  end

  test "PATH loses the release's directories and keeps the rest in order" do
    env = %{
      "RELEASE_ROOT" => "/opt/runner/releases/1",
      "PATH" =>
        "/opt/runner/releases/1/erts-16/bin:/opt/runner/releases/1/bin:/home/u/.asdf/shims:" <>
          "/opt/runner/releases/10/bin:/usr/bin"
    }

    assert Session.release_path(env) == [
             {"PATH", "/home/u/.asdf/shims:/opt/runner/releases/10/bin:/usr/bin"}
           ]
  end

  test "unset_names/0 is the billing key and repo-locating names, and no more" do
    # Parity with an attended session: nothing else in the daemon's environment is withheld.
    unset = Session.unset_names()
    assert "ANTHROPIC_API_KEY" in unset
    assert "GIT_DIR" in unset

    for name <-
          ~w(SSH_AUTH_SOCK GH_TOKEN GPG_AGENT_INFO GIT_ASKPASS GIT_SSH_COMMAND GIT_SSH NPM_TOKEN HOME) do
      refute name in unset, "#{name} is withheld from a session"
    end
  end

  test "outside a release PATH is left alone" do
    assert Session.release_path(%{"PATH" => "/usr/bin"}) == []
    assert Session.release_path(%{"RELEASE_ROOT" => "", "PATH" => "/usr/bin"}) == []
  end
end
