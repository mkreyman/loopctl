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

  describe "unset_names/2: which subtractions a caller may override" do
    # Values are placeholders: tests never record real environment values.
    @daemon %{
      "NPM_TOKEN" => "v",
      "SECRET_KEY_BASE" => "v",
      "ANTHROPIC_API_KEY" => "v",
      "GIT_SSH_COMMAND" => "v",
      "HOME" => "/home/u"
    }

    test "a SHAPE-matched name the caller supplies is not unset" do
      # session_env is the escape hatch: per repo, mode 600, revocable. The heuristic cannot tell
      # a Phoenix test secret from a credential, and the operator can.
      assert "SECRET_KEY_BASE" in Session.unset_names(@daemon, [])
      refute "SECRET_KEY_BASE" in Session.unset_names(@daemon, [{"SECRET_KEY_BASE", "v"}])
      # Only the one named: supplying one shaped name keeps nothing else.
      assert "NPM_TOKEN" in Session.unset_names(@daemon, [{"SECRET_KEY_BASE", "v"}])
    end

    test "an UNCONDITIONAL name stays unset however it is supplied" do
      # The name lists are not a heuristic and have no case for an exception: there is no session
      # that wants the runner's API key or a program git executes. Config refuses these in
      # session_env, and a caller reaching Session.run/1 with :env directly does not get past it.
      supplied = [{"ANTHROPIC_API_KEY", "v"}, {"GIT_SSH_COMMAND", "v"}]
      unset = Session.unset_names(@daemon, supplied)
      assert "ANTHROPIC_API_KEY" in unset
      assert "GIT_SSH_COMMAND" in unset
    end

    test "a name of no interest is never unset, supplied or not" do
      refute "HOME" in Session.unset_names(@daemon, [])
      refute "HOME" in Session.unset_names(@daemon, [{"HOME", "/home/u"}])
    end
  end

  test "outside a release PATH is left alone" do
    assert Session.release_path(%{"PATH" => "/usr/bin"}) == []
    assert Session.release_path(%{"RELEASE_ROOT" => "", "PATH" => "/usr/bin"}) == []
  end
end
