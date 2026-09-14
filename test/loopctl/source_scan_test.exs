defmodule Loopctl.SourceScanTest do
  @moduledoc """
  Issue #803 round 3 — `Loopctl.SourceScan` exists because two drift guards matched RAW TEXT and
  a `#` comment satisfied them.

  Both guards scan `lib/loopctl/**` for callers of a gate function and compare the result
  against a declaration in both directions, and both call the "declared but does not enforce"
  direction the dangerous one — which is exactly the direction a comment could fake. Neither
  guard can prove the fix on its own: reverting the scanner to `String.contains?` leaves them
  green, because no module in the tree happens to mention the call in prose. (`bin/mutate.sh`
  said so — exit 1.) So the property is asserted here, on source this test writes itself.
  """

  use ExUnit.Case, async: true

  alias Loopctl.SourceScan

  setup do
    dir = Path.join(System.tmp_dir!(), "source_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "calls?/3" do
    test "finds a qualified call, and a call through the bare alias", %{dir: dir} do
      qualified = write(dir, "a.ex", "Loopctl.Runners.custody_halted?(tenant_id)")
      aliased = write(dir, "b.ex", "Runners.custody_halted?(tenant_id)")

      assert SourceScan.calls?(qualified, :Runners, :custody_halted?)
      assert SourceScan.calls?(aliased, :Runners, :custody_halted?)
    end

    test "a COMMENT naming the call is not a call", %{dir: dir} do
      path = write(dir, "c.ex", "# Runners.custody_halted?(tenant_id) is the gate\n    :ok")

      # The whole reason this module exists. A module declared as enforcing a gate, whose only
      # mention of it is prose explaining the gate, passed the text-matching version.
      refute SourceScan.calls?(path, :Runners, :custody_halted?)
    end

    test "a STRING or a doc containing the call is not a call", %{dir: dir} do
      string = write(dir, "d.ex", ~s|message = "call Runners.custody_halted?(id) first"|)
      doc = write_with_doc(dir, "e.ex", "Gated by `Runners.custody_halted?(tenant_id)`.")

      refute SourceScan.calls?(string, :Runners, :custody_halted?)
      refute SourceScan.calls?(doc, :Runners, :custody_halted?)
    end

    test "a DIFFERENT module's function of the same name is not a match", %{dir: dir} do
      path = write(dir, "f.ex", "Tenants.custody_halted?(tenant)")

      # Not pedantry: `Tenants.custody_halted?/1` takes an already-loaded struct and is the
      # monitor's READ, not a gate. A bare-function-name scan would report the monitor as
      # halt-enforcing and the guard would assert something it does not mean.
      refute SourceScan.calls?(path, :Runners, :custody_halted?)
      assert SourceScan.calls?(path, :Tenants, :custody_halted?)
    end

    test "matches at any arity, including zero", %{dir: dir} do
      path = write(dir, "g.ex", "Runners.custody_halted?()")
      assert SourceScan.calls?(path, :Runners, :custody_halted?)
    end
  end

  describe "callers/3" do
    test "returns the declaring module names of the files that call it", %{dir: dir} do
      write(dir, "caller.ex", "Runners.custody_halted?(id)", "Sample.Caller")
      write(dir, "mentioner.ex", "# Runners.custody_halted?(id)\n    :ok", "Sample.Mentioner")

      assert SourceScan.callers(Path.join(dir, "*.ex"), :Runners, :custody_halted?) ==
               ["Sample.Caller"]
    end

    test "an unparseable file RAISES rather than being skipped", %{dir: dir} do
      path = Path.join(dir, "broken.ex")
      File.write!(path, "defmodule Broken do\n  def f( do\nend")

      # A file the scanner cannot read is a file the guard cannot vouch for. Skipping it is how
      # a scan starts passing for the wrong reason. `TokenMissingError` rather than
      # `SyntaxError` — both are what `Code.string_to_quoted!/1` raises, and which one depends
      # on how the source is broken, so this asserts the class the caller actually sees.
      assert_raise TokenMissingError, fn ->
        SourceScan.callers(Path.join(dir, "*.ex"), :Runners, :custody_halted?)
      end
    end
  end

  defp write(dir, file, body, module \\ nil) do
    module = module || "Sample.M#{System.unique_integer([:positive])}"
    path = Path.join(dir, file)
    File.write!(path, "defmodule #{module} do\n  def f(tenant_id) do\n    #{body}\n  end\nend\n")
    path
  end

  defp write_with_doc(dir, file, doc) do
    path = Path.join(dir, file)
    module = "Sample.M#{System.unique_integer([:positive])}"

    File.write!(path, """
    defmodule #{module} do
      @moduledoc \"\"\"
      #{doc}
      \"\"\"
    end
    """)

    path
  end
end
