defmodule ChgAdapter.DigestTest do
  use ExUnit.Case, async: false

  alias ChgAdapter.Digest

  @source """
  defmodule ChgDigestSample do
    defstruct at: nil
    def file, do: __ENV__.file
    def meta, do: %URI{path: __ENV__.file}
    def body, do: BODY
  end
  """

  setup do
    Code.put_compiler_option(:ignore_module_conflict, true)
    root = Path.join(System.tmp_dir!(), "chg-digest-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    on_exit(fn ->
      :code.purge(ChgDigestSample)
      :code.delete(ChgDigestSample)
      Code.put_compiler_option(:ignore_module_conflict, false)
    end)

    %{root: root}
  end

  # Compiles the sample at `<root>/<name>` and returns its digest.
  defp digest(root, name, body) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "ebin"))
    src = Path.join(dir, "sample.ex")
    File.write!(src, String.replace(@source, "BODY", body))

    {:ok, _, _} =
      Kernel.ParallelCompiler.compile_to_path([src], Path.join(dir, "ebin"),
        return_diagnostics: true
      )

    Digest.of_file(String.to_charlist(Path.join(dir, "ebin/Elixir.ChgDigestSample.beam")), dir)
  end

  test "the same source at two paths has one digest, though literals hold the path", %{root: r} do
    a = digest(r, "a", ":one")
    assert is_binary(a)
    assert a == digest(r, "elsewhere-longer", ":one")
  end

  test "a change in behaviour changes the digest", %{root: r} do
    refute digest(r, "a", ":one") == digest(r, "b", ":two")
  end

  test "a line shift leaves source locations in literals alone, not other lines", %{root: r} do
    loc = "%{file: __ENV__.file, line: __ENV__.line, kw: [file: \"f\", line: __ENV__.line]}"
    assert digest(r, "a", loc) == digest(r, "b", "\n\n" <> loc)
    refute digest(r, "c", "[line: 3]") == digest(r, "d", "[line: 4]")
  end

  test "a cache keeps the digest of a beam whose bytes are unchanged, and only then", %{root: r} do
    fresh = digest(r, "a", ":one")
    dir = Path.join(r, "a")
    :code.purge(ChgDigestSample)

    {:module, _} =
      :code.load_abs(String.to_charlist(Path.join(dir, "ebin/Elixir.ChgDigestSample")))

    cache = Path.join(r, "digests.etf")

    assert Digest.of_modules([ChgDigestSample], dir, cache) == %{ChgDigestSample => fresh}

    {v, ^dir, %{ChgDigestSample => {key, _}}} = cache |> File.read!() |> :erlang.binary_to_term()
    File.write!(cache, :erlang.term_to_binary({v, dir, %{ChgDigestSample => {key, "cached"}}}))
    assert Digest.of_modules([ChgDigestSample], dir, cache) == %{ChgDigestSample => "cached"}

    File.write!(
      cache,
      :erlang.term_to_binary({v, dir, %{ChgDigestSample => {"other", "cached"}}})
    )

    assert Digest.of_modules([ChgDigestSample], dir, cache) == %{ChgDigestSample => fresh}
  end

  # A map with atom keys is encoded in atom table order, which differs between VMs: the
  # verifier's run that records digests and the run that compares with them. Each peer
  # runs this VM's own emulator and code path, and makes the keys' atoms in its order.
  test "a map literal has one digest in every VM, whatever order its keys' atoms were made in",
       %{root: r} do
    digest(r, "a", "%{zz_chg_key: 1, aa_chg_key: 2, mm_chg_key: %{yy_chg_key: 3, bb_chg_key: 4}}")
    beam = String.to_charlist(Path.join(r, "a/ebin/Elixir.ChgDigestSample.beam"))

    run = fn keys ->
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: paths})

      try do
        for k <- keys, do: :peer.call(peer, :erlang, :binary_to_atom, [k])
        :peer.call(peer, Digest, :of_file, [beam, Path.join(r, "a")])
      after
        :peer.stop(peer)
      end
    end

    keys = ~w(zz_chg_key aa_chg_key mm_chg_key yy_chg_key bb_chg_key)
    assert <<_::binary-16>> = d = run.(keys)
    assert run.(Enum.reverse(keys)) == d
  end

  test "an unreadable beam has no digest" do
    assert Digest.of_file(~c"/nonexistent.beam", "/") == nil
  end
end
