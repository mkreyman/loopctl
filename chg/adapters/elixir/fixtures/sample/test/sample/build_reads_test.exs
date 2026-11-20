defmodule Sample.BuildReadsTest do
  use Sample.Case, async: true

  # A guard that scans compiled code without running it, and a read through the app's
  # priv dir: both resolve under _build. The module is named at run time so no compile
  # reference ties this file to it.
  test "scans a beam" do
    beam = :code.which(Module.concat(["Sample", "Scanned"]))
    assert {:ok, {_, [atoms: _]}} = :beam_lib.chunks(beam, [:atoms])
  end

  test "reads priv" do
    path = Path.join(:code.priv_dir(:sample), "greeting.txt")
    assert File.read!(path) =~ "hello"
  end
end
