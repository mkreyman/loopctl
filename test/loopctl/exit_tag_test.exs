defmodule Loopctl.ExitTagTest do
  @moduledoc """
  #558 — `Loopctl.ExitTag` had five clauses, five call sites and no test of its own.

  That is a silent-deletion hazard rather than a coverage gap: removing the
  crash-PROPAGATION clause degrades every such exit to `"unknown"` at all five sites, and
  nothing anywhere fails. The clause list IS the module — it was extracted precisely
  because four private copies had already diverged into two behaviours — so it needs a test
  that pins each clause to the SHAPE it exists for.

  Every reason below is a real shape DBConnection/Postgrex produce, not a convenient
  fixture. That distinction is the whole point: a tagger with only an atom clause passes
  against a hand-written `exit(:noproc)` while degrading every genuine production exit.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ExitTag

  describe "the shapes DBConnection actually exits with" do
    test "a {reason, call} tuple — an absent or unstarted pool" do
      # NOT a bare `:noproc`. This is the shape that matters, and the one an atom-only
      # tagger silently misses.
      assert ExitTag.tag({:noproc, {DBConnection, :execute, []}}) == "noproc"
    end

    test "a {reason, call} tuple — a wedged pool's checkout timeout" do
      assert ExitTag.tag({:timeout, {DBConnection.Holder, :checkout, []}}) == "timeout"
    end

    test "crash PROPAGATION carrying an exception struct" do
      # The pooled process died OF something rather than being absent. This is the clause
      # the module was extracted to preserve: deleting it degrades this to "unknown" at
      # every call site, and dying of a backend error is a different investigation from an
      # unrecognised reason.
      reason = {{%Postgrex.Error{message: "boom"}, [{:erl, :f, 0, []}]}, {DBConnection, :x, []}}

      assert ExitTag.tag(reason) == "Postgrex.Error"
    end

    test "crash propagation carrying a bare atom reason" do
      reason = {{:badarg, [{:erl, :f, 0, []}]}, {DBConnection, :x, []}}

      assert ExitTag.tag(reason) == "badarg"
    end
  end

  describe "the ordinary shapes" do
    test "a bare atom is its own tag" do
      assert ExitTag.tag(:noproc) == "noproc"
      assert ExitTag.tag(:shutdown) == "shutdown"
      assert ExitTag.tag(:killed) == "killed"
    end

    test "anything unrecognised collapses to a single catch-all" do
      assert ExitTag.tag("a string") == "unknown"
      assert ExitTag.tag(%{not: :a_reason}) == "unknown"
      assert ExitTag.tag(12_345) == "unknown"
    end
  end

  describe "the bound the tag exists to keep" do
    test "it never returns an exception MESSAGE, only a module name" do
      # The message on a Postgrex/DBConnection struct names the backend host, database and
      # role. Every call site logs or tags with this value, so leaking the message here
      # leaks it at all five.
      reason =
        {{%DBConnection.ConnectionError{message: "tcp connect (db.internal:5432): timeout"}, []},
         {DBConnection, :execute, []}}

      tag = ExitTag.tag(reason)

      assert tag == "DBConnection.ConnectionError"
      refute tag =~ "db.internal"
      refute tag =~ "5432"
    end

    test "it never returns the call tuple, which carries module, function and args" do
      tag = ExitTag.tag({:noproc, {DBConnection, :execute, [:secret_arg]}})

      assert tag == "noproc"
      refute tag =~ "secret_arg"
      refute tag =~ "DBConnection"
    end
  end
end
