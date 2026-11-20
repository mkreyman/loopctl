# Writes the module digests (ChgAdapter.Digest) of one compiled ebin, with each module's
# source and whether it is a protocol implementation, as an ETF map.
#
#   elixir digests.exs <ebin> <project root> <out.etf>

Code.require_file(Path.expand("../../adapters/elixir/lib/chg_adapter/digest.ex", __DIR__))

[ebin, root, out] = System.argv()

rows =
  for f <- Path.wildcard(Path.join(ebin, "*.beam")) do
    m = f |> Path.basename(".beam") |> String.to_atom()
    c = String.to_charlist(f)
    {:ok, {_, [compile_info: ci, exports: ex]}} = :beam_lib.chunks(c, [:compile_info, :exports])
    src = ci |> Keyword.get(:source, ~c"") |> to_string() |> Path.relative_to(root)
    {m, ChgAdapter.Digest.of_file(c, root), src, {:__impl__, 1} in ex}
  end

File.write!(
  out,
  :erlang.term_to_binary(
    %{
      digests: Map.new(rows, fn {m, d, _, _} -> {m, d} end),
      sources: Map.new(rows, fn {m, _, s, _} -> {m, s} end),
      impls: for({m, _, _, true} <- rows, do: m)
    },
    [:compressed]
  )
)

IO.puts("#{length(rows)} modules")
