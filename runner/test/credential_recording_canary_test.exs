defmodule LoopctlRunner.CredentialRecordingCanaryTest do
  @moduledoc """
  Binds the fake CLI's environment recording to the names `Session` unsets and the credentials a
  session inherits.

  Every test that proves a credential does not reach a session does it by refuting a line in the
  fixture's `env` file, so a name the fixture does not RECORD makes that refutation pass whether
  or not the unset happened — silently, and for as long as the test lives. The fixture matches by
  category and by shape rather than by name, which is what makes that unlikely; this is what makes
  it FALSIFIABLE. It runs the real `test/support/bin/claude` with each name set and fails on any
  name that comes back unrecorded, so a name added to `Session` with no fixture category to catch
  it fails HERE rather than passing vacuously over there.
  """

  use ExUnit.Case, async: true

  alias LoopctlRunner.{Session, TestSupport}

  # Credentials a session now INHERITS, which `RunTest` proves by asserting them PRESENT: the
  # fixture must record them, or that assertion could never pass and would be deleted as flaky.
  @inherited ~w(SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO GH_TOKEN GITHUB_TOKEN GIT_ASKPASS
                SSH_ASKPASS GIT_SSH_COMMAND GIT_SSH NPM_TOKEN AWS_SECRET_ACCESS_KEY HEX_API_KEY
                PGPASSWORD)

  test "the fixture records every name the session unsets, and every credential it inherits" do
    names = Session.credential_env() ++ @inherited
    recorded = record(names)

    for name <- names do
      assert "#{name} PRESENT" in recorded,
             "#{name} is unset for a session but the fixture does not record it, so a test " <>
               "refuting its presence cannot fail"
    end
  end

  test "ordinary session furniture is not recorded as a credential" do
    keep = ~w(HOME PATH LANG SHELL USER LOGNAME PWD XDG_RUNTIME_DIR XDG_DATA_DIRS
              DBUS_SESSION_BUS_ADDRESS TERM MIX_ENV)

    recorded = record(keep)

    for name <- keep do
      refute "#{name} PRESENT" in recorded, "#{name} is recorded as a credential"
    end
  end

  # Names the fixture needs in order to RUN, which a probe must never overwrite. `System.cmd/3`
  # merges `env:` over the caller's environment, so passing PATH here as a placeholder leaves the
  # script unable to find `env`, `awk` or `realpath`: the redirect still creates the file, there
  # is no `set -e`, the script exits 0, and every `refute ... PRESENT` below passes against an
  # EMPTY recording. That is how this canary was unfalsifiable when it was written, and it is the
  # same defect class the canary exists to catch.
  @must_keep ~w(PATH HOME)

  # Proof the fixture RAN and wrote, independent of every credential category and shape branch:
  # matched by the LOOP_ arm, which is not what any of these tests is about.
  @alive {"LOOP_CANARY_ALIVE", "yes"}

  # Runs the fixture itself, in a controlled environment, and returns the lines it recorded.
  # The fixture's own awk is the thing under test, so nothing here may restate it.
  defp record(names) do
    state = TestSupport.tmp_dir!("recording-canary")
    fixture = Path.join(TestSupport.fake_bin_dir(), "claude")

    # Values are placeholders and are never read back: tests never record environment values.
    env =
      names
      |> Enum.reject(&(&1 in @must_keep))
      |> Enum.map(&{&1, "placeholder"})
      |> Enum.concat([@alive, {"FAKE_STATE_DIR", state}])

    {_out, 0} = System.cmd("bash", [fixture], env: env, stderr_to_stdout: true, into: "")

    lines = state |> Path.join("env") |> File.read!() |> String.split("\n", trim: true)

    {alive_name, alive_value} = @alive

    assert "#{alive_name}=#{alive_value}" in lines,
           "the fixture recorded nothing, so nothing below can fail: check that this probe did " <>
             "not overwrite a variable the script needs to run"

    lines
  end
end
