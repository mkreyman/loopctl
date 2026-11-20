defmodule Sample.SharedReadsTest do
  use Sample.Case, async: true

  # The same reads as build_reads_test, of a path dependency's build instead of the app's.
  test "scans a dependency's beam" do
    beam = :code.which(Module.concat(["Shared"]))
    assert {:ok, {_, [atoms: _]}} = :beam_lib.chunks(beam, [:atoms])
  end

  test "reads a dependency's priv" do
    path = Path.join(:code.priv_dir(:shared), "note.txt")
    assert File.read!(path) =~ "from shared"
  end
end
