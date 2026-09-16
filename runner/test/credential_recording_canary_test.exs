defmodule LoopctlRunner.CredentialRecordingCanaryTest do
  @moduledoc """
  Binds the fake CLI's environment recording to the names `Session` actually unsets.

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

  # Names no category or shape of the fixture's is allowed to depend on: if the shape deny in
  # `Session.credential_shaped?/1` matches them, the fixture must record them too, or the test
  # that proves the shape deny works would pass with the deny deleted.
  @shape_probes ~w(NPM_TOKEN AWS_SECRET_ACCESS_KEY HEX_API_KEY PGPASSWORD FLY_API_TOKEN
                   SOME_VENDOR_PRIVATE_KEY DB_PASSWD SIGNING_KEY_ID)

  test "the fixture records every name the session unsets, and every shape the deny matches" do
    names = Session.credential_env() ++ Session.git_program_env() ++ @shape_probes
    recorded = record(names)

    for name <- names do
      assert "#{name} PRESENT" in recorded,
             "#{name} is unset for a session but the fixture does not record it, so a test " <>
               "refuting its presence cannot fail"
    end
  end

  test "the shape probes are ones the deny actually matches" do
    # Without this the test above degrades into a statement about the fixture alone: a probe the
    # deny does not match is not evidence about anything a session is protected from.
    for name <- @shape_probes do
      assert Session.credential_shaped?(name), "#{name} is not matched by the shape deny"
    end
  end

  test "ordinary session furniture is neither shape-denied nor recorded" do
    # The other half of a deny's correctness: a shape that matches everything protects nothing
    # and breaks the runner. HOME and PATH in particular are what mix, hex and asdf resolve out
    # of, and XDG_RUNTIME_DIR is inherited deliberately.
    keep = ~w(HOME PATH LANG SHELL USER LOGNAME PWD XDG_RUNTIME_DIR XDG_DATA_DIRS
              DBUS_SESSION_BUS_ADDRESS TERM MIX_ENV)

    for name <- keep do
      refute Session.credential_shaped?(name), "#{name} would be unset for every session"
    end

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
