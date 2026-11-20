defmodule ChgAdapter.Digest do
  @moduledoc """
  A digest of a compiled module's behaviour, equal for the same source compiled twice, at
  two paths, on two machines.

  Coverage selection compares these, not source files, so a change that alters a module
  only through compile time (a macro expanded into it, a struct default, a module
  attribute, an `@external_resource`) still counts as changing it. `beam_lib:md5/1` is not
  enough: two builds of one commit differ in ways that change nothing a test can see, and
  every module that differs is selected as if it had changed. So the digest is taken over
  the disassembled code, with what a build varies made canonical:

    * the project root in literals (`__ENV__.file`, which `Logger` and `raise` put there)
      is replaced by a token;
    * `__mix_recompile__?/0`, which only Mix calls, is left out: Phoenix's
      `embed_templates` puts a hash of the templates' absolute paths in it;
    * a line shift does not change what a module does, so line instructions are dropped,
      and so is the line of a source location in a literal: a map or keyword list holding
      both `file` and an integer `line`, as Logger metadata and Ecto query expressions do.
      A `line` without a `file` beside it may be data, and stays;
    * labels are numbered within their function, and functions are taken in name order;
    * compiler-generated functions (lambdas, comprehensions) are numbered in the order
      the compiler emits them, which moves with everything below, so each is named by its
      own content, and the fun table's index and hash of the module are dropped;
    * the key/value pairs a map instruction builds or matches are sorted by key: OTP 26+
      orders a map's atom keys by atom index, the order the VM first saw each atom, which
      the parallel compiler varies from build to build;
    * a LiveView fingerprint (an integer hash of the template's compile-time structure,
      which carries per-compile counters) is zeroed; the template's static parts, which
      it fingerprints, still count;
    * literals are encoded `:deterministic`, so a map literal is the same bytes whatever
      order its keys' atoms were made in.

  Code a compile generates by iterating a map can still come out in another order;
  `ChgAdapter.Atoms` makes the atom order itself the same in every compiling VM, which
  removes most of that. What still differs looks altered, which only selects more.
  """

  # Bump when normalisation changes, so a cache of the old digests is not reused and a
  # record of the old ones is not compared.
  @version 4

  # Functions only Mix calls, which no test can observe. Phoenix's `embed_templates`
  # compiles into `__mix_recompile__?/0` a hash of the templates' absolute paths, which
  # no root token can stand in for: every such module would differ between two checkouts.
  @unseen [{:__mix_recompile__?, 0}]

  @doc "The form of digest this adapter makes; a record keeps it, and only equal forms compare."
  def version, do: @version

  @doc """
  Digests of `modules` (those with a beam on disk), keyed by module. With a `cache` file,
  a beam whose bytes are as they were last time keeps its digest, so only what the last
  compile rewrote is normalised again.
  """
  def of_modules(modules, root \\ File.cwd!(), cache \\ nil) do
    old = read_cache(cache, root)

    entries =
      for(m <- modules, path = beam(m), path != nil, do: {m, path})
      |> Task.async_stream(
        fn {m, path} ->
          with {:ok, bin} <- File.read(path) do
            key = :crypto.hash(:md5, bin)

            case old do
              %{^m => {^key, d}} -> {m, {key, d}}
              _ -> {m, {key, of_file(path, root)}}
            end
          end
        end,
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, {_m, {_key, _d}} = entry} -> [entry]
        {:ok, {:error, _}} -> []
      end)
      |> Map.new()

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

  @doc "The digest of the beam at `path` (a charlist); nil when it cannot be read."
  def of_file(path, root) do
    case :beam_disasm.file(path) do
      {:beam_file, _module, exports, _attributes, _info, code} ->
        exports =
          for({name, arity, _label} <- exports, {name, arity} not in @unseen, do: {name, arity})
          |> Enum.sort()

        :crypto.hash(
          :md5,
          :erlang.term_to_binary({exports, functions(code, root)}, [:deterministic])
        )

      {:error, _, _} ->
        nil
    end
  end

  defp functions(code, root) do
    funs =
      for {:function, name, arity, _entry, ins} <- code,
          {name, arity} not in @unseen,
          do: {name, arity, local(ins, root)}

    names = rename(funs)

    funs
    |> Enum.map(fn {name, arity, ins} ->
      {Map.get(names, {name, arity}, name), arity, rewrite(ins, names, nil)}
    end)
    |> Enum.sort()
  end

  # One function's instructions, without what varies between builds of the same source.
  defp local(ins, root) do
    ins = Enum.reject(ins, &(match?({:line, _}, &1) or match?({:executable_line, _, _}, &1)))
    labels = for({:label, l} <- ins, do: l) |> Enum.with_index() |> Map.new()

    Enum.map(ins, fn
      {:label, l} -> {:label, Map.fetch!(labels, l)}
      i -> i |> instruction(labels, root) |> maps()
    end)
  end

  defp instruction({:f, l}, labels, _root) when is_map_key(labels, l), do: {:f, labels[l]}
  defp instruction({:literal, t}, _labels, root), do: {:literal, walk(t, root)}

  defp instruction({:make_fun3, f, _index, _uniq, dst, free}, labels, root),
    do: {:make_fun3, f, 0, 0, instruction(dst, labels, root), instruction(free, labels, root)}

  defp instruction(t, labels, root) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&instruction(&1, labels, root)) |> List.to_tuple()

  defp instruction(l, labels, root) when is_list(l),
    do: Enum.map(l, &instruction(&1, labels, root))

  defp instruction(x, _labels, _root), do: x

  defp maps({op, f, src, dst, live, {:list, kv}}) when op in [:put_map_assoc, :put_map_exact],
    do: {op, f, src, dst, live, {:list, pairs(kv)}}

  defp maps({:get_map_elements, f, src, {:list, kv}}),
    do: {:get_map_elements, f, src, {:list, pairs(kv)}}

  defp maps({:has_map_fields, f, src, {:list, keys}}),
    do: {:has_map_fields, f, src, {:list, Enum.sort(keys)}}

  defp maps(i), do: i

  defp pairs(kv) do
    pairs = Enum.chunk_every(kv, 2)

    pairs =
      if Enum.any?(pairs, &match?([{:atom, :static}, _], &1)),
        do: Enum.map(pairs, &fingerprint/1),
        else: pairs

    # Sorting cannot merge two pairs into one meaning: beam_validator refuses a map
    # instruction of more than one pair unless every key is a literal (`literal_required`),
    # so the compiler gives a key in a register an instruction of its own.
    pairs |> Enum.sort() |> Enum.concat()
  end

  defp fingerprint([{:atom, :fingerprint}, {:integer, _}]),
    do: [{:atom, :fingerprint}, {:integer, 0}]

  defp fingerprint(pair), do: pair

  # Generated functions (their names start with "-") named by their content, refined until
  # the naming stops changing: a lambda that calls another is named by the other's name.
  defp rename(funs) do
    generated = for {name, arity, _} <- funs, generated?(name), do: {name, arity}
    start = Map.new(generated, &{&1, :generated})

    Enum.reduce_while(1..20, start, fn _, names ->
      next =
        for {name, arity, ins} <- funs, generated?(name), into: %{} do
          hash =
            :crypto.hash(
              :md5,
              :erlang.term_to_binary(rewrite(ins, names, {name, arity}), [:deterministic])
            )

          {{name, arity}, :"-generated-#{Base.encode16(hash, case: :lower)}-"}
        end

      if classes(next) == classes(names), do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp generated?(name), do: match?("-" <> _, Atom.to_string(name))

  defp classes(names) do
    names
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Map.values()
    |> Enum.map(&Enum.sort/1)
    |> Enum.sort()
  end

  # Every reference to a generated function (a call, a fun, its own func_info) by the
  # function's name in `names`; `self`'s own references by `:self`.
  defp rewrite(ins, names, self) do
    name = fn n, a ->
      cond do
        {n, a} == self -> :self
        is_map_key(names, {n, a}) -> names[{n, a}]
        true -> n
      end
    end

    deep(ins, fn
      {:func_info, m, {:atom, n}, a} -> {:func_info, m, {:atom, name.(n, a)}, a}
      {m, n, a} when is_atom(m) and is_atom(n) and is_integer(a) -> {m, name.(n, a), a}
      x -> x
    end)
  end

  defp deep(t, f) when is_tuple(t) do
    case f.(t) do
      ^t -> t |> Tuple.to_list() |> Enum.map(&deep(&1, f)) |> List.to_tuple()
      other -> other
    end
  end

  defp deep(l, f) when is_list(l), do: Enum.map(l, &deep(&1, f))
  defp deep(x, f), do: f.(x)

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

    m =
      if :maps.is_key(:static, m) and is_integer(:maps.get(:fingerprint, m, nil)),
        do: %{m | fingerprint: 0},
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
