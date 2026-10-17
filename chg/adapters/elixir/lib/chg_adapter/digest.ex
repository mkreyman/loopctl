defmodule ChgAdapter.Digest do
  @moduledoc """
  A digest of a compiled module's behaviour, equal for the same source compiled at two
  paths.

  Coverage selection compares these, not source files, so a change that alters a module
  only through compile time (a macro expanded into it, a struct default, a module
  attribute, an `@external_resource`) still counts as changing it. `beam_lib:md5/1` is not
  enough: `__ENV__.file`, which `Logger` and `raise` put in literals, is absolute, so every
  module would differ between the verifier's checkout and a hydrated workspace. This hashes
  the chunks that define behaviour, with the project root in literals replaced by a token
  and the fun table's code hash (which covers those literals) left out.

  A line shift alone does not change what a module does, so the line table is left out,
  and so is the line of a source location in a literal: a map or keyword list holding both
  `file` and an integer `line`, as Logger metadata and Ecto query expressions do. A `line`
  without a `file` beside it may be data, and stays. A line number compiled into code
  rather than a literal still counts, which only ever selects more.
  """

  # Bump when normalisation changes, so a cache of the old digests is not reused.
  @version 2
  @chunks [~c"AtU8", ~c"Code", ~c"StrT", ~c"ImpT", ~c"ExpT", ~c"FunT", ~c"LitT"]

  @doc """
  Digests of `modules` (those with a beam on disk), keyed by module. With a `cache` file,
  a beam whose bytes are as they were last time keeps its digest, so only what the last
  compile rewrote is normalised again.
  """
  def of_modules(modules, root \\ File.cwd!(), cache \\ nil) do
    old = read_cache(cache, root)

    entries =
      for m <- modules, path = beam(m), path != nil, {:ok, bin} <- [File.read(path)], into: %{} do
        key = :crypto.hash(:md5, bin)

        case old do
          %{^m => {^key, d}} -> {m, {key, d}}
          _ -> {m, {key, of_file(path, root)}}
        end
      end

    if cache,
      do: ChgAdapter.write_atomic!(cache, :erlang.term_to_binary({@version, root, entries}))

    Map.new(entries, fn {m, {_, d}} -> {m, d} end)
  end

  defp read_cache(nil, _root), do: %{}

  defp read_cache(path, root) do
    with {:ok, bin} <- File.read(path),
         {@version, ^root, entries} when is_map(entries) <- :erlang.binary_to_term(bin) do
      entries
    else
      _ -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp beam(m) do
    case :code.which(m) do
      path when is_list(path) -> path
      _ -> nil
    end
  end

  @doc "The digest of the beam at `path`; nil when it cannot be read."
  def of_file(path, root) do
    case :beam_lib.chunks(path, @chunks, [:allow_missing_chunks]) do
      {:ok, {_, chunks}} ->
        parts = for {id, data} <- chunks, is_binary(data), do: [id, normalize(id, data, root)]
        :crypto.hash(:md5, :erlang.term_to_binary(parts))

      {:error, _, _} ->
        nil
    end
  end

  # LitT: a 4-byte uncompressed size (0 when stored uncompressed), then the zlib'd table:
  # a count, and per literal a 4-byte size and its external term format.
  defp normalize(~c"LitT", <<0::32, table::binary>>, root), do: literals(table, root)

  defp normalize(~c"LitT", <<_::32, z::binary>>, root),
    do: literals(:zlib.uncompress(z), root)

  # FunT: a count, then six words per fun; the last (old_uniq) hashes the module's code
  # with its literals, so it carries the path too. The rest stays.
  defp normalize(~c"FunT", <<n::32, entries::binary>>, _root) do
    funs = for <<f::binary-size(20), _uniq::32 <- entries>>, into: <<>>, do: f
    <<n::32, funs::binary>>
  end

  defp normalize(_, data, _), do: data

  defp literals(<<n::32, rest::binary>>, root) do
    {terms, _} =
      Enum.map_reduce(1..n//1, rest, fn _, <<s::32, t::binary-size(s), r::binary>> ->
        {t |> :erlang.binary_to_term() |> walk(root), r}
      end)

    :erlang.term_to_binary(terms)
  end

  defp walk(b, root) when is_binary(b), do: :binary.replace(b, root, "<root>", [:global])

  defp walk(l, root) when is_list(l) do
    cond do
      printable?(l) -> l |> List.to_string() |> walk(root) |> String.to_charlist()
      location?(l) -> l |> List.keyreplace(:line, 0, {:line, 0}) |> walk_list(root)
      true -> walk_list(l, root)
    end
  end

  defp walk(t, root) when is_tuple(t),
    do: t |> Tuple.to_list() |> walk_list(root) |> List.to_tuple()

  # Structs too: `:maps` functions do not dispatch to Enumerable.
  defp walk(m, root) when is_map(m) do
    m =
      if :maps.is_key(:file, m) and is_integer(:maps.get(:line, m, nil)),
        do: %{m | line: 0},
        else: m

    m |> :maps.to_list() |> walk_list(root) |> :maps.from_list()
  end

  defp walk(x, _), do: x

  # Improper lists keep their tail.
  defp walk_list([h | t], root), do: [walk(h, root) | walk_list(t, root)]
  defp walk_list([], _), do: []
  defp walk_list(tail, root), do: walk(tail, root)

  defp location?(l),
    do:
      proper?(l) and List.keymember?(l, :file, 0) and
        is_integer(List.keyfind(l, :line, 0, {nil, nil}) |> elem(1))

  defp printable?([]), do: false
  defp printable?(l), do: proper?(l) and List.ascii_printable?(l)

  defp proper?([_ | t]), do: proper?(t)
  defp proper?([]), do: true
  defp proper?(_), do: false
end
